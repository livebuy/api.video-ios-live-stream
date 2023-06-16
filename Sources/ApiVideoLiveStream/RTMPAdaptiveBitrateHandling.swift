//
//  RTMPAdaptiveBitrateHandling.swift
//  ApiVideoLiveStream
//
//  Created by mihaichifor on 13.06.2023.
//

import Foundation
import HaishinKit

class RTMPAdaptiveBitrateHandling: NSObject, RTMPConnectionDelegate {
    let cooldownPeriod: TimeInterval
    var lastAdjustmentTime: Date
    let lowPassFilterScalar: Double
    var bandwidth: Double
    var threshold: Double
    var targetBitrate: UInt32
    
    let movingAveragePeriod: Int = 10  // last 10 measurements
    var pastBytesOutPerSecond: [Int32] = []
    
    init(startBitrate: UInt32, targetBitrate: UInt32, cooldownPeriod: TimeInterval, lowPassFilterScalar: Double = 0.08) {
        self.cooldownPeriod = cooldownPeriod
        self.lowPassFilterScalar = lowPassFilterScalar
        self.bandwidth = Double(startBitrate)
        self.threshold = Double(startBitrate) * 0.75
        self.targetBitrate = targetBitrate
        self.lastAdjustmentTime = Date(timeIntervalSince1970: 0)
    }
    
    func calculateMovingAverage(_ newBytesOutPerSecond: Int32) -> Double {
        if pastBytesOutPerSecond.count >= movingAveragePeriod {
            pastBytesOutPerSecond.removeFirst()
        }
        
        pastBytesOutPerSecond.append(newBytesOutPerSecond)
        let sum = pastBytesOutPerSecond.reduce(0, { x, y in x + Int(y) })
        let average: Double = Double(sum) / Double(pastBytesOutPerSecond.count)
        
        return average
    }
    
    public func resetTargetBitrate(bitRate: UInt32) {
        self.bandwidth = Double(bitRate)
        self.threshold = Double(bitRate) * 0.75
        self.targetBitrate = bitRate
        self.pastBytesOutPerSecond = []
    }
    
    public func connection(_ connection: RTMPConnection, updateStats stream: RTMPStream) {
        let currentBps = Double(connection.currentBytesOutPerSecond) * 8
        print("current bitrate: \(currentBps / 1000)")
        bandwidth = currentBps * lowPassFilterScalar + bandwidth * (1 - lowPassFilterScalar)
        // adaptive threshold - making threshold as 75% of the bandwidth
        threshold = bandwidth * 0.75
    }
    
    public func connection(_ connection: RTMPConnection, publishSufficientBWOccured stream: RTMPStream) {
        if Date().timeIntervalSince(lastAdjustmentTime) < cooldownPeriod {
            return
        }
        
        let currentBps = Double(connection.currentBytesOutPerSecond) * 8
//        let adjustment = (bandwidth - Double(stream.videoSettings.bitRate)) * 0.25
        let adjustment = 50 * 1000
        // increase bitrate proportionally to the difference between bandwidth and current bitrate
        let newBitrate = min(Int(stream.videoSettings.bitRate) + Int(adjustment), Int(self.targetBitrate))
        
        if currentBps > threshold && Double(stream.videoSettings.bitRate) < bandwidth && newBitrate < self.targetBitrate {
            print("sufficient... old bitrate: \(stream.videoSettings.bitRate / 1000), new bitrate: \(newBitrate / 1000), adjustment was: \(adjustment / 1000)")
            stream.videoSettings.bitRate = UInt32(newBitrate)
            lastAdjustmentTime = Date()
        }
    }
    
    public func connection(_ connection: RTMPConnection, publishInsufficientBWOccured stream: RTMPStream) {
        let currentBps = connection.currentBytesOutPerSecond * 8
        let movingAverage = calculateMovingAverage(currentBps)
        let adjustment = (Double(stream.videoSettings.bitRate) - bandwidth) * 0.25
        // decrease bitrate proportionally to the difference between bandwidth and current bitrate
        let newBitrate = Int(stream.videoSettings.bitRate) - Int(adjustment)
        
        if Date().timeIntervalSince(lastAdjustmentTime) < cooldownPeriod {
            return
        }
        
        if movingAverage > threshold && Double(stream.videoSettings.bitRate) > bandwidth {
            print("insufficient... old bitrate: \(stream.videoSettings.bitRate / 1000), new bitrate: \(newBitrate / 1000), adjustment was: \(adjustment / 1000)")
            stream.videoSettings.bitRate = UInt32(newBitrate)
            lastAdjustmentTime = Date()
        }
    }
}
