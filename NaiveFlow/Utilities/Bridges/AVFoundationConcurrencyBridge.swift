//
//  AVFoundationConcurrencyBridge.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/18/26.
//

import AVFoundation

extension AVCaptureSession: @unchecked @retroactive Sendable { }
