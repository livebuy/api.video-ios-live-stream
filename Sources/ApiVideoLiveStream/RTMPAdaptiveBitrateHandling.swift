//
//  RTMPAdaptiveBitrateHandling.swift
//  ApiVideoLiveStream
//
//  Created by mihaichifor on 13.06.2023.
//

import Foundation
import HaishinKit

struct StreamingProfile: Equatable {
    let bitrate: UInt32
    let resolution: CGSize
    let keyframeInterval: Double
    
    static func ==(lhs: StreamingProfile, rhs: StreamingProfile) -> Bool {
        return lhs.bitrate == rhs.bitrate &&
        lhs.resolution == rhs.resolution &&
        lhs.keyframeInterval == rhs.keyframeInterval
    }
}

/**
 Recommended settings according to Mux: https://docs.mux.com/guides/video/configure-broadcast-software#recommended-encoder-settings
 */
let profiles: [StreamingProfile] = [
    StreamingProfile(bitrate: 5000000, resolution: CGSize(width: 1920, height: 1080), keyframeInterval: 2),
    StreamingProfile(bitrate: 3500000, resolution: CGSize(width: 1280, height: 720), keyframeInterval: 2),
    StreamingProfile(bitrate: 1000000, resolution: CGSize(width: 854, height: 480), keyframeInterval: 5)
]

func findSuitableStreamingProfile(_ bitrate: UInt32) -> StreamingProfile {
    let suitableProfiles = profiles.filter { $0.bitrate >= bitrate }
    let sortedProfiles = suitableProfiles.sorted { $0.bitrate < $1.bitrate }
    return sortedProfiles.first ?? profiles.first!
}

func currentDateIsInCooldownPeriod(lastAdjustmentDate: Date, cooldownPeriod: TimeInterval) -> Bool {
    return Date().timeIntervalSince(lastAdjustmentDate) < cooldownPeriod
}

class RTMPAdaptiveBitrateHandling: NSObject, RTMPConnectionDelegate {
    let cooldownPeriod: TimeInterval
    var lastAdjustmentTime: Date
    let lowPassFilterScalar: Double
    var bandwidth: Double
    var threshold: Double
    var targetBitrate: UInt32
    var currentStreamingProfile: StreamingProfile
    
    let movingAveragePeriod: Int = 10  // last 10 measurements
    var pastBytesOutPerSecond: [Int32] = []
    
    init(startBitrate: UInt32, targetBitrate: UInt32, cooldownPeriod: TimeInterval, lowPassFilterScalar: Double = 0.08) {
        self.cooldownPeriod = cooldownPeriod
        self.lowPassFilterScalar = lowPassFilterScalar
        self.bandwidth = Double(startBitrate)
        self.threshold = Double(startBitrate) * 0.75
        self.targetBitrate = targetBitrate
        self.lastAdjustmentTime = Date(timeIntervalSince1970: 0)
        self.currentStreamingProfile = findSuitableStreamingProfile(startBitrate)
    }
    
    private func updatePastBytesOutPerSecond(_ newBytesOutPerSecond: Int32) {
        if pastBytesOutPerSecond.count >= movingAveragePeriod {
            pastBytesOutPerSecond.removeFirst()
        }
        
        pastBytesOutPerSecond.append(newBytesOutPerSecond)
    }
    
    private func calculateMovingAverage(_ newBytesOutPerSecond: Int32) -> Double {
        let sum = pastBytesOutPerSecond.reduce(0, { x, y in x + Int(y) })
        let average: Double = Double(sum) / Double(pastBytesOutPerSecond.count)
        
        return average
    }
    
    private func setNewBitrate(stream: RTMPStream, bitRate: UInt32, increased: Bool, adjustment: Int) {
        let suitableProfile = findSuitableStreamingProfile(bitRate)
        
        if (self.currentStreamingProfile != suitableProfile), let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
            stream.videoSettings.videoSize = .init(width: Int32(orientation.isLandscape ? suitableProfile.resolution.width : suitableProfile.resolution.height), height: Int32(orientation.isLandscape ? suitableProfile.resolution.height : suitableProfile.resolution.width))
            stream.videoSettings.maxKeyFrameIntervalDuration = Int32(suitableProfile.keyframeInterval)
            self.currentStreamingProfile = suitableProfile
            print("\(increased ? "increased" : "decreased")... bitrate profile changed. resolution: \(suitableProfile.resolution), keyInterval: \(suitableProfile.keyframeInterval)")
        }
        
        stream.videoSettings.bitRate = UInt32(bitRate)
        lastAdjustmentTime = Date()
        print("\(increased ? "increased" : "decreased")... new bitrate: \(Int(bitRate / 1000)), adjustment was: \(Int(adjustment / 1000))")
    }
    
    public func resetTargetBitrate(bitRate: UInt32) {
        self.bandwidth = Double(bitRate)
        self.threshold = Double(bitRate) * 0.75
        self.targetBitrate = bitRate
        self.pastBytesOutPerSecond = []
    }
    
    public func connection(_ connection: RTMPConnection, updateStats stream: RTMPStream) {
        let currentBps = Double(connection.currentBytesOutPerSecond) * 8
        print("current bitrate: \(Int(currentBps / 1000)), bandwidth: \(Int(bandwidth / 1000))")
        bandwidth = currentBps * lowPassFilterScalar + bandwidth * (1 - lowPassFilterScalar)
        // adaptive threshold - making threshold as 75% of the bandwidth
        threshold = bandwidth * 0.75
        
        self.updatePastBytesOutPerSecond(Int32(currentBps))
    }
    
    public func connection(_ connection: RTMPConnection, publishSufficientBWOccured stream: RTMPStream) {
        if currentDateIsInCooldownPeriod(lastAdjustmentDate: self.lastAdjustmentTime, cooldownPeriod: self.cooldownPeriod) {
            return
        }
        let currentBps = Double(connection.currentBytesOutPerSecond) * 8
        //        let adjustment = (bandwidth - Double(stream.videoSettings.bitRate)) * 0.25
        let adjustment = 150 * 1000
        // increase bitrate proportionally to the difference between bandwidth and current bitrate
        let newBitrate = min(Int(stream.videoSettings.bitRate) + Int(adjustment), Int(self.targetBitrate))
        
        if currentBps > threshold && Double(stream.videoSettings.bitRate) < bandwidth && newBitrate < self.targetBitrate {
            self.setNewBitrate(stream: stream, bitRate: UInt32(newBitrate), increased: true, adjustment: adjustment)
        }
    }
    
    public func connection(_ connection: RTMPConnection, publishInsufficientBWOccured stream: RTMPStream) {
        if currentDateIsInCooldownPeriod(lastAdjustmentDate: self.lastAdjustmentTime, cooldownPeriod: self.cooldownPeriod) {
            return
        }
        
        let currentBps = connection.currentBytesOutPerSecond * 8
        let movingAverage = calculateMovingAverage(currentBps)
        let adjustment = (Double(stream.videoSettings.bitRate) - bandwidth) * 0.2
        // decrease bitrate proportionally to the difference between bandwidth and current bitrate
        let newBitrate = Int(stream.videoSettings.bitRate) - Int(adjustment)
        
        if movingAverage > threshold && Double(stream.videoSettings.bitRate) > bandwidth {
            self.setNewBitrate(stream: stream, bitRate: UInt32(newBitrate), increased: false, adjustment: Int(adjustment))
        }
    }
}
