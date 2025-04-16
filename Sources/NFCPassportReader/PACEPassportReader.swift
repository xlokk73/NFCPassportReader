//
//  PACEPassportReader.swift
//  NFCPassportReader
//
//  Created by Manwel Bugeja Personal on 16/04/2025.
//


import Foundation
import OSLog

#if !os(macOS)
import UIKit
import CoreNFC

@available(iOS 15, *)
public class PACEPassportReader : NSObject {
    
    private typealias PACEContinuation = CheckedContinuation<TagReader, Error>
    private var paceContinuation: PACEContinuation?
    
    public weak var trackingDelegate: PassportReaderTrackingDelegate?
    private var passport : NFCPassportModel = NFCPassportModel()
    
    private var readerSession: NFCTagReaderSession?
    private var mrzKey : String = ""
    private var dataAmountToReadOverride : Int? = nil
    private var nfcViewDisplayMessageHandler: ((NFCViewDisplayMessage) -> String?)?
    private var shouldNotReportNextReaderSessionInvalidationErrorUserCanceled : Bool = false
    
    // Flag to control whether the session should be kept open after authentication
    private var keepSessionActive: Bool = true
    
    public init(dataAmountToReadOverride: Int? = nil) {
        super.init()
        self.dataAmountToReadOverride = dataAmountToReadOverride
    }
    
    /// This function allows you to override the amount of data the TagReader tries to read from the NFC
    /// chip. NOTE - this really shouldn't be used for production but is useful for testing as different
    /// passports support different data amounts.
    /// It appears that the most reliable is 0xA0 (160 chars) but some will support arbitary reads (0xFF or 256)
    public func overrideNFCDataAmountToRead( amount: Int ) {
        dataAmountToReadOverride = amount
    }
    
    /// Set whether to keep the NFC session active after PACE authentication
    /// - Parameter keep: true to keep session active, false to invalidate after authentication
    public func setKeepSessionActive(_ keep: Bool) {
        keepSessionActive = keep
    }
    
    /// Performs PACE authentication and returns a TagReader with an established PACE session
    /// - Parameters:
    ///   - mrzKey: The MRZ key to use for PACE authentication
    ///   - customDisplayMessage: Optional handler for customizing NFC display messages
    ///   - keepSessionActive: Whether to keep the NFC session active after authentication
    /// - Returns: A TagReader with an established PACE session
    /// - Throws: NFCPassportReaderError if any errors occur during the PACE process
    public func authenticateWithPACE(mrzKey: String, customDisplayMessage: ((NFCViewDisplayMessage) -> String?)? = nil, keepSessionActive: Bool = true) async throws -> TagReader {
        
        self.passport = NFCPassportModel()
        self.mrzKey = mrzKey
        self.nfcViewDisplayMessageHandler = customDisplayMessage
        self.keepSessionActive = keepSessionActive
        
        guard NFCNDEFReaderSession.readingAvailable else {
            throw NFCPassportReaderError.NFCNotSupported
        }
        
        if NFCTagReaderSession.readingAvailable {
            readerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)
            
            self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.requestPresentPassport)
            readerSession?.begin()
        }
        
        return try await withCheckedThrowingContinuation({ (continuation: PACEContinuation) in
            self.paceContinuation = continuation
        })
    }
    
    private func updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage) {
        self.readerSession?.alertMessage = self.nfcViewDisplayMessageHandler?(alertMessage) ?? alertMessage.description
    }
    
    private func invalidateSession(errorMessage: NFCViewDisplayMessage, error: NFCPassportReaderError) {
        // Mark the next 'invalid session' error as not reportable (we're about to cause it by invalidating the
        // session). The real error is reported back with the call to the completed handler
        self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
        self.readerSession?.invalidate(errorMessage: self.nfcViewDisplayMessageHandler?(errorMessage) ?? errorMessage.description)
        paceContinuation?.resume(throwing: error)
        paceContinuation = nil
    }
    
    private func performPACEAuthentication(with tag: NFCISO7816Tag) async throws -> TagReader {
        let tagReader = TagReader(tag: tag)
        
        if let newAmount = self.dataAmountToReadOverride {
            tagReader.overrideDataAmountToRead(newAmount: newAmount)
        }
        
        tagReader.progress = { [unowned self] (progress) in
            self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.authenticatingWithPassport(progress))
        }
        
        trackingDelegate?.nfcTagDetected()
        
        // Read CardAccess
        let cardAccessData = try await tagReader.readCardAccess()
        let cardAccess = try CardAccess(cardAccessData)
        passport.cardAccess = cardAccess
        
        trackingDelegate?.readCardAccess(cardAccess: cardAccess)
        
        // Perform PACE
        trackingDelegate?.paceStarted()
        
        Logger.passportReader.info("Starting Password Authenticated Connection Establishment (PACE)")
        
        let paceHandler = try PACEHandler(cardAccess: cardAccess, tagReader: tagReader)
        try await paceHandler.doPACE(mrzKey: mrzKey)
        passport.PACEStatus = .success
        Logger.passportReader.debug("PACE Succeeded")
        
        trackingDelegate?.paceSucceeded()
        
        // Re-select passport application after PACE
        _ = try await tagReader.selectPassportApplication()
        
        // Only show success message if we're keeping the session active
        if keepSessionActive {
            self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.successfulRead)
        } else {
            // If not keeping session active, invalidate it now
            self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
            self.readerSession?.invalidate()
        }
        
        return tagReader
    }
}

@available(iOS 15, *)
extension PACEPassportReader : NFCTagReaderSessionDelegate {
    // MARK: - NFCTagReaderSessionDelegate
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        Logger.passportReader.debug("tagReaderSessionDidBecomeActive")
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Logger.passportReader.debug("tagReaderSession:didInvalidateWithError - \(error.localizedDescription)")
        self.readerSession?.invalidate()
        self.readerSession = nil
        
        if let readerError = error as? NFCReaderError, readerError.code == NFCReaderError.readerSessionInvalidationErrorUserCanceled
            && self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled {
            
            self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = false
        } else {
            var userError = NFCPassportReaderError.UnexpectedError
            if let readerError = error as? NFCReaderError {
                Logger.passportReader.error("tagReaderSession:didInvalidateWithError - Got NFCReaderError - \(readerError.localizedDescription)")
                switch (readerError.code) {
                case NFCReaderError.readerSessionInvalidationErrorUserCanceled:
                    Logger.passportReader.error("     - User cancelled session")
                    userError = NFCPassportReaderError.UserCanceled
                case NFCReaderError.readerSessionInvalidationErrorSessionTimeout:
                    Logger.passportReader.error("     - Session timeout")
                    userError = NFCPassportReaderError.TimeOutError
                default:
                    Logger.passportReader.error("     - some other error - \(readerError.localizedDescription)")
                    userError = NFCPassportReaderError.UnexpectedError
                }
            } else {
                Logger.passportReader.error("tagReaderSession:didInvalidateWithError - Received error - \(error.localizedDescription)")
            }
            paceContinuation?.resume(throwing: userError)
            paceContinuation = nil
        }
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Logger.passportReader.debug("tagReaderSession:didDetect - found \(tags)")
        if tags.count > 1 {
            Logger.passportReader.debug("tagReaderSession:more than 1 tag detected! - \(tags)")
            
            let errorMessage = NFCViewDisplayMessage.error(.MoreThanOneTagFound)
            self.invalidateSession(errorMessage: errorMessage, error: NFCPassportReaderError.MoreThanOneTagFound)
            return
        }
        
        let tag = tags.first!
        var passportTag: NFCISO7816Tag
        switch tags.first! {
        case let .iso7816(tag):
            passportTag = tag
        default:
            Logger.passportReader.debug("tagReaderSession:invalid tag detected!!!")
            
            let errorMessage = NFCViewDisplayMessage.error(NFCPassportReaderError.TagNotValid)
            self.invalidateSession(errorMessage: errorMessage, error: NFCPassportReaderError.TagNotValid)
            return
        }
        
        Task { [passportTag] in
            do {
                try await session.connect(to: tag)
                
                Logger.passportReader.debug("tagReaderSession:connected to tag - starting PACE authentication")
                self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.authenticatingWithPassport(0))
                
                let authenticatedTagReader = try await self.performPACEAuthentication(with: passportTag)
                
                // IMPORTANT: Don't invalidate session if we want to keep it active for additional commands
                if !self.keepSessionActive {
                    self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
                    self.readerSession?.invalidate()
                }
                
                paceContinuation?.resume(returning: authenticatedTagReader)
                paceContinuation = nil
                
            } catch let error as NFCPassportReaderError {
                trackingDelegate?.paceFailed()
                passport.PACEStatus = .failed
                
                let errorMessage = NFCViewDisplayMessage.error(error)
                self.invalidateSession(errorMessage: errorMessage, error: error)
            } catch {
                Logger.passportReader.debug("tagReaderSession:failed to connect to tag - \(error.localizedDescription)")
                
                // .readerTransceiveErrorTagResponseError is thrown when a "connection lost" scenario is forced by moving the phone away from the NFC chip
                // .readerTransceiveErrorTagConnectionLost is never thrown for this scenario, but added for the sake of completeness
                if let nfcError = error as? NFCReaderError,
                   nfcError.errorCode == NFCReaderError.readerTransceiveErrorTagResponseError.rawValue ||
                    nfcError.errorCode == NFCReaderError.readerTransceiveErrorTagConnectionLost.rawValue {
                    let errorMessage = NFCViewDisplayMessage.error(NFCPassportReaderError.ConnectionError)
                    self.invalidateSession(errorMessage: errorMessage, error: NFCPassportReaderError.ConnectionError)
                } else {
                    let errorMessage = NFCViewDisplayMessage.error(NFCPassportReaderError.Unknown(error))
                    self.invalidateSession(errorMessage: errorMessage, error: NFCPassportReaderError.Unknown(error))
                }
            }
        }
    }
}
#endif
