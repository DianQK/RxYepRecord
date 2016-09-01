//
//  NewFeedVoiceRecordViewController.swift
//  Yep
//
//  Created by nixzhu on 15/11/25.
//  Copyright © 2015年 Catch Inc. All rights reserved.
//

import UIKit
import AVFoundation
import RxSwift
import RxCocoa
import RxAutomaton

struct FeedVoice {
    
    let fileURL: URL
    let sampleValuesCount: Int
    let limitedSampleValues: [CGFloat]
}

struct Message {
    public var imageFileURL: URL?
    public var videoFileURL: URL?
}

final class NewFeedVoiceRecordViewController: UIViewController {

    @IBOutlet fileprivate weak var cancelButton: UIBarButtonItem!
    @IBOutlet fileprivate weak var nextButton: UIBarButtonItem!

    @IBOutlet fileprivate weak var voiceRecordSampleView: VoiceRecordSampleView!
    @IBOutlet fileprivate weak var voiceIndicatorImageView: UIImageView!
    @IBOutlet fileprivate weak var voiceIndicatorImageViewCenterXConstraint: NSLayoutConstraint!

    @IBOutlet fileprivate weak var timeLabel: UILabel! 

    @IBOutlet fileprivate weak var voiceRecordButton: RecordButton!
    @IBOutlet fileprivate weak var playButton: UIButton!
    @IBOutlet fileprivate weak var resetButton: UIButton!
    
    enum State {
        case reset // default
        case recording
        case recorded // readyPlay
        case playing
        case playPausing
    }
    
    enum Input {
        case record
        case stop // 停止录音
        case play
        case pause
        case reset
    }

    fileprivate var sampleValues: [CGFloat] = [] {
        didSet {
            let count = sampleValues.count
            let frequency = 10
            let minutes = count / frequency / 60
            let seconds = count / frequency - minutes * 60
            let subSeconds = count - seconds * frequency - minutes * 60 * frequency

            timeLabel.text = String(format: "%02d:%02d.%d", minutes, seconds, subSeconds)
        }
    }

    fileprivate var audioPlaying: Bool = false {
        willSet {
            if newValue != audioPlaying {
                if newValue {
                    playButton.setImage(R.image.button_voice_pause(), for: .normal)
                } else {
                    playButton.setImage(R.image.button_voice_play(), for: .normal)
                }
            }
        }
    }

    fileprivate var audioPlayedDuration: TimeInterval = 0 {
        willSet {
            guard newValue != audioPlayedDuration else {
                return
            }

            let sampleStep: CGFloat = (4 + 2)
            let fullWidth = voiceRecordSampleView.bounds.width

            let fullOffsetX = CGFloat(sampleValues.count) * sampleStep

            let currentOffsetX = CGFloat(newValue) * (10 * sampleStep)

            // 0.5 用于回去
            let duration: TimeInterval = newValue > audioPlayedDuration ? 0.02 : 0.5

            if fullOffsetX > fullWidth {

                if currentOffsetX <= fullWidth * 0.5 {
                    UIView.animate(withDuration: duration, delay: 0.0, options: .curveLinear, animations: { [weak self] in
                        self?.voiceIndicatorImageViewCenterXConstraint.constant = -fullWidth * 0.5 + 2 + currentOffsetX
                        self?.view.layoutIfNeeded()
                    }, completion: { _ in })

                } else {
                    voiceRecordSampleView.sampleCollectionView.setContentOffset(CGPoint(x: currentOffsetX - fullWidth * 0.5 , y: 0), animated: false)
                }

            } else {
                UIView.animate(withDuration: duration, delay: 0.0, options: .curveLinear, animations: { [weak self] in
                    self?.voiceIndicatorImageViewCenterXConstraint.constant = -fullWidth * 0.5 + 2 + currentOffsetX
                    self?.view.layoutIfNeeded()
                }, completion: { _ in })
            }
        }
    }

    fileprivate var feedVoice: FeedVoice?

    deinit {
        print("deinit NewFeedVoiceRecord")
    }
    
    private var _automaton: Automaton<State, Input>?
    private let disposeBag = DisposeBag()

    override func viewDidLoad() {
        super.viewDidLoad()

        // 如果进来前有声音在播放，令其停止
        if let audioPlayer = YepAudioService.shared.audioPlayer , audioPlayer.isPlaying {
            audioPlayer.pause()
        } // TODO: delete

        AudioBot.stopPlay()
        
        let mappings: [Automaton<State, Input>.NextMapping] = [
        /*  Input   |   fromState                                   => toState       |  Effect */
        /* ------------------------------------------------------------------------------------*/
            .record | (.reset                                       => .recording)   | .empty(),
            .stop   | (.recording                                   => .recorded)    | .empty(),
            .play   | ([.recorded, .playPausing].contains           => .playing)     | .empty(),
            .pause  | (.playing                                     => .playPausing) | .empty(),
            .reset  | ([.recorded, .playing, .playPausing].contains => .reset)       | .empty()
        ]

        let (inputSignal, inputObserver) = Observable<Input>.pipe()
        
        let automaton = Automaton(state: .reset, input: inputSignal, mapping: reduce(mappings), strategy: .latest)
        self._automaton = automaton
        
        automaton.replies
            .subscribe(onNext: { (reply) in
                print("received reply = \(reply)")
                })
            .addDisposableTo(disposeBag)
        
        automaton.state.asObservable()
            .subscribe(onNext: { (state) in
                print("current state: \(state)")
                })
            .addDisposableTo(disposeBag)
        
        do {
            Observable.from([
                voiceRecordButton.rx.tap.withLatestFrom(automaton.state.asObservable()).map { (state) in
                    switch state {
                    case .recording:
                        return Input.stop
                    case .reset:
                        return Input.record
                    default:
                        fatalError()
                    }
                },
                resetButton.rx.tap.map { Input.reset },
                playButton.rx.tap.withLatestFrom(automaton.state.asObservable()).map { (state) in
                    switch state {
                    case .playing:
                        return Input.pause
                    case .playPausing, .recorded:
                        return Input.play
                    default:
                        fatalError()
                    }
                },
            ])
                .merge()
                .subscribe(onNext: inputObserver.onNext)
                .addDisposableTo(disposeBag)
        }
        
        do {
            automaton.state.asObservable()
                .subscribe(onNext: { [weak self] (state) in
                    guard let `self` = self else { return }
                    switch state {
                    case .recording:
                        proposeToAccess(.microphone, agreed: {
                            
                            do {
                                let decibelSamplePeriodicReport: AudioBot.PeriodicReport = (reportingFrequency: 10, report: { decibelSample in
                                    
                                    DispatchQueue.main.async {
                                        let value = CGFloat(decibelSample)
                                        self.sampleValues.append(value)
                                        self.voiceRecordSampleView.appendSampleValue(value: value)
                                    }
                                })
                                AudioBot.mixWithOthersWhenRecording = true
                                try AudioBot.startRecordAudioToFileURL(nil, forUsage: .normal, withDecibelSamplePeriodicReport: decibelSamplePeriodicReport)
                                
                                self.nextButton.isEnabled = false
                                
                                self.voiceIndicatorImageView.alpha = 0
                                
                                UIView.animate(withDuration: 0.25, delay: 0.0, options: .curveEaseInOut, animations: {
                                    self.voiceRecordButton.alpha = 1
                                    self.voiceRecordButton.appearance = .recording
                                    
                                    self.playButton.alpha = 0
                                    self.resetButton.alpha = 0
                                    }, completion: nil)
                                
                            } catch let error {
                                print("record error: \(error)")
                            }
                            }, rejected: { [weak self] in
                                self?.alertCanNotAccessMicrophone()
                            })
                    case .recorded:
                        AudioBot.stopRecord { fileURL, duration, decibelSamples in
                            guard duration > YepConfig.AudioRecord.shortestDuration else {
                                YepAlert.alertSorry(message: NSLocalizedString("Voice recording time is too short!", comment: ""), inViewController: self, withDismissAction: {
//                                    inputObserver.onNext(.reset)
                                    })
                                return
                            }
                            
                            let compressedDecibelSamples = AudioBot.compressDecibelSamples(decibelSamples, withSamplingInterval: 1, minNumberOfDecibelSamples: 10, maxNumberOfDecibelSamples: 50)
                            let feedVoice = FeedVoice(fileURL: fileURL, sampleValuesCount: decibelSamples.count, limitedSampleValues: compressedDecibelSamples.map({ CGFloat($0) }))
                            self.feedVoice = feedVoice
                            
                            self.nextButton.isEnabled = true
                            
                            self.voiceIndicatorImageView.alpha = 0
                            
                            UIView.animate(withDuration: 0.25, delay: 0.0, options: UIViewAnimationOptions(), animations: {
                                self.voiceRecordButton.alpha = 0
                                self.playButton.alpha = 1
                                self.resetButton.alpha = 1
                                }, completion: nil)
                            
                            let fullWidth = self.voiceRecordSampleView.bounds.width
                            
                            if !self.voiceRecordSampleView.sampleValues.isEmpty {
                                let firstIndexPath = IndexPath(item: 0, section: 0)
                                self.voiceRecordSampleView.sampleCollectionView.scrollToItem(at: firstIndexPath, at: .left, animated: true)
                            }
                            
                            UIView.animate(withDuration: 0.25, delay: 0.0, options: .curveEaseInOut, animations: {
                                self.voiceIndicatorImageView.alpha = 1
                                }, completion: { _ in
                                    UIView.animate(withDuration: 0.75, delay: 0.0, options: .curveEaseInOut, animations: {
                                        self.voiceIndicatorImageViewCenterXConstraint.constant = -fullWidth * 0.5 + 2
                                        self.view.layoutIfNeeded()
                                        }, completion: { _ in })
                            })
                        }
                    case .playing:
                        guard let fileURL = self.feedVoice?.fileURL else {
                            return
                        }
                        do {
                            let progressPeriodicReport: AudioBot.PeriodicReport = (reportingFrequency: 60, report: { progress in
                                //print("progress: \(progress)")
                            })
                            
                            try AudioBot.startPlayAudioAtFileURL(fileURL, fromTime: self.audioPlayedDuration, withProgressPeriodicReport: progressPeriodicReport, finish: { success in
                                
                                self.audioPlayedDuration = 0
                                
//                                if success {
//                                    self.state = .recorded
//                                }
                                })
                            
                            AudioBot.reportPlayingDuration = { duration in
                                self.audioPlayedDuration = duration
                            }
                            
                            self.audioPlaying = true
                            
                        } catch let error {
                            print("AudioBot: \(error)")
                        }
                    case .reset:
                        do {
                            if let audioPlayer = YepAudioService.shared.audioPlayer , audioPlayer.isPlaying {
                                audioPlayer.pause()
                            }
                            AudioBot.stopPlay()
                            
                            self.voiceRecordSampleView.reset()
                            self.sampleValues = []
                            
                            self.audioPlaying = false
                            self.audioPlayedDuration = 0
                        }
                        
                        self.nextButton.isEnabled = false
                        
                        self.voiceIndicatorImageView.alpha = 0
                        
                        UIView.animate(withDuration: 0.25, delay: 0.0, options: UIViewAnimationOptions(), animations: {
                            self.voiceRecordButton.alpha = 1
                            self.voiceRecordButton.appearance = .default
                            
                            self.playButton.alpha = 0
                            self.resetButton.alpha = 0
                            }, completion: nil)
                        
                        self.voiceIndicatorImageViewCenterXConstraint.constant = 0
                        self.view.layoutIfNeeded()
                    case .playPausing:
                        AudioBot.pausePlay()
                    }
                })
                .addDisposableTo(disposeBag)
        }
        
    }

    // MARK: - Actions

    @IBAction fileprivate func cancel(_ sender: UIBarButtonItem) {

        AudioBot.stopPlay()

        dismiss(animated: true) {
            AudioBot.stopRecord { _, _, _ in
            }
        }
    }

    @IBAction fileprivate func next(_ sender: UIBarButtonItem) {

        AudioBot.stopPlay()

        if let feedVoice = feedVoice {
//            performSegueWithIdentifier("showNewFeed", sender: Box(feedVoice))
        }
    }

}
