import Foundation
import AVFoundation
import AudioToolbox
import os
import Speech
import UIKit
import MediaPlayer

/// to play audio and speak text, overrides mute
class SoundPlayer {
    
    // MARK: - properties
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryPlaySound)

    /// audioplayer
    private var audioPlayer:AVAudioPlayer?
    
    // MARK: - initializer
    
    /// token of the most recent request to start playing, used to cancel a start that is waiting for the volume change
    private var playRequestToken = UUID()
    
    /// plays the sound, overrides mute
    /// - parameters:
    ///     - soundFileName : name of the file with the sound, the filename must include the extension, eg mp3
    ///     - raiseVolumeToAtLeast : optional. If the system volume is lower than this value (0.0 - 1.0), the system volume is raised to it before the sound starts. A higher volume is never lowered, and the volume is not restored afterwards.
    public func playSound(soundFileName:String, raiseVolumeToAtLeast: Float? = nil) {
        
        guard let url = Bundle.main.url(forResource: soundFileName, withExtension: "") else {
            trace("in playSound, could not create url with sound %{public}@", log: self.log, category: ConstantsLog.categoryPlaySound, type: .error, soundFileName)
            return
        }
        
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback, options: AVAudioSession.CategoryOptions.mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch let error {
            trace("in playSound, could not set AVAudioSession category to playback and mixwithOthers, error = %{public}@", log: self.log, category: ConstantsLog.categoryPlaySound, type: .error, error.localizedDescription)
        }
        
        let token = UUID()
        playRequestToken = token
        
        guard let targetVolume = raiseVolumeToAtLeast, AVAudioSession.sharedInstance().outputVolume < targetVolume else {
            startPlaying(url: url, soundFileName: soundFileName)
            return
        }
        
        trace("in playSound, system volume %{public}@ is lower than %{public}@, raising it before playing", log: self.log, category: ConstantsLog.categoryPlaySound, type: .info, AVAudioSession.sharedInstance().outputVolume.description, targetVolume.description)
        
        setSystemVolume(to: targetVolume) { [weak self] in
            // start playing, unless stopPlaying or another playSound was called in the meantime
            guard let self = self, self.playRequestToken == token else { return }
            self.startPlaying(url: url, soundFileName: soundFileName)
        }
    }
    
    /// creates the AVAudioPlayer and starts playing
    private func startPlaying(url: URL, soundFileName: String) {
        do {
            try audioPlayer = AVAudioPlayer(contentsOf: url)
            
            if let audioPlayer = audioPlayer {
                audioPlayer.play()
            } else {
                trace("in playSound, could not create url with sound %{public}@", log: self.log, category: ConstantsLog.categoryPlaySound, type: .error, soundFileName)
            }
        } catch let error {
            trace("in playSound, exception while trying to play sound %{public}@, error = %{public}@", log: self.log, category: ConstantsLog.categoryPlaySound, type: .error, error.localizedDescription)
        }
    }
    
    /// iOS has no public API to set the system volume. The usual workaround is to move the slider of a (hidden) MPVolumeView.
    /// The slider only exists a moment after the MPVolumeView has been added to a window, so completion is called after a short delay.
    /// completion is always called, also if the volume could not be changed, so the sound still plays.
    private func setSystemVolume(to volume: Float, completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
            let window = windows.first { $0.isKeyWindow } ?? windows.first
            
            let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
            volumeView.alpha = 0.01
            window?.addSubview(volumeView)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                    slider.value = volume
                    slider.sendActions(for: .valueChanged)
                } else {
                    trace("in setSystemVolume, could not find the volume slider", log: self.log, category: ConstantsLog.categoryPlaySound, type: .error)
                }
                
                // give iOS a moment to apply the new volume before the sound starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    volumeView.removeFromSuperview()
                    completion()
                }
            }
        }
    }
    
    /// is the PlaySound playing or not
    public func isPlaying() -> Bool {
        if let audioPlayer = audioPlayer {
            return audioPlayer.isPlaying
        }
        return false
    }
    
    /// if playSound is playing, then stop
    public func stopPlaying() {
        // cancel a start that is still waiting for the volume change
        playRequestToken = UUID()
        if isPlaying() {
            if let audioPlayer = audioPlayer {
                audioPlayer.stop()
            }
        }
    }
    
}

/// Stores per alert type name the volume (in percent) the system volume must be raised to before the alert sound is played (only used if override mute is on).
/// No entry means the feature is off for that alert type.
/// Kept in UserDefaults, not in Core Data, so no Core Data model migration is needed.
enum AlertTypeVolumeBoost {
    
    static let defaultPercent = 50
    static let minimumPercent = 10
    static let maximumPercent = 100
    
    private static let key = "alertTypeVolumePercentByName"
    
    /// key used by the first version of this feature, which only supported 50%
    private static let legacyKey = "alertTypeNamesWithRaiseVolumeTo50"
    
    private static var percents: [String: Int] {
        get {
            var result = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
            // migrate the first version
            if let legacyNames = UserDefaults.standard.stringArray(forKey: legacyKey) {
                for name in legacyNames where result[name] == nil { result[name] = defaultPercent }
                UserDefaults.standard.set(result, forKey: key)
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
            return result
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    
    static func isEnabled(alertTypeName: String) -> Bool {
        return percents[alertTypeName] != nil
    }
    
    /// the stored percentage, nil if the feature is off for this alert type
    static func percent(alertTypeName: String) -> Int? {
        return percents[alertTypeName]
    }
    
    /// the volume (0.0 - 1.0) to raise to, nil if the feature is off for this alert type
    static func volume(alertTypeName: String) -> Float? {
        guard let percent = percents[alertTypeName] else { return nil }
        return Float(min(max(percent, minimumPercent), maximumPercent)) / 100
    }
    
    /// - parameter percent: nil switches the feature off
    static func set(percent: Int?, alertTypeName: String) {
        var current = percents
        if let percent {
            current[alertTypeName] = min(max(percent, minimumPercent), maximumPercent)
        } else {
            current.removeValue(forKey: alertTypeName)
        }
        percents = current
    }
    
    /// to be used when an alert type is renamed, so the setting follows the alert type
    static func rename(from oldName: String, to newName: String) {
        guard oldName != newName, let percent = percent(alertTypeName: oldName) else { return }
        set(percent: nil, alertTypeName: oldName)
        set(percent: percent, alertTypeName: newName)
    }
    
}
