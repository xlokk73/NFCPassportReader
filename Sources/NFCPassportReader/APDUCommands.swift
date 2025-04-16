//
//  APDUCommands.swift
//  NFCPassportReader
//
//  Created by Manwel Bugeja Personal on 16/04/2025.
//


import Foundation
import CoreNFC

public class APDUCommands {
    
    // Master File AID provided by you
    static let MF_AID: [UInt8] = [0xD2, 0x76, 0x00, 0x00, 0x98, 0x4D, 0x4C, 0x41, 0x56, 0x31]
    
    /// Selects the Master File using the provided AID
    /// - Parameter tagReader: A TagReader with an established secure session
    /// - Returns: The response from the passport
    public static func selectMasterFile(tagReader: TagReader) async throws -> ResponseAPDU {
        // Create a SELECT APDU command
        // CLA: 0x00
        // INS: 0xA4 (SELECT)
        // P1: 0x04 (Select by AID)
        // P2: 0x0C (First or only occurrence)
        // Data: MF_AID 
        // Le: -1 (Return all available bytes)
        let cmd = NFCISO7816APDU(
            instructionClass: 0x00, 
            instructionCode: 0xA4, 
            p1Parameter: 0x04, 
            p2Parameter: 0x0C, 
            data: Data(MF_AID), 
            expectedResponseLength: -1
        )
        
        // Send the command and return the response
        return try await tagReader.send(cmd: cmd)
    }
    
    /// Example of sending a custom APDU command
    /// - Parameters:
    ///   - tagReader: A TagReader with an established secure session
    ///   - cla: Instruction class
    ///   - ins: Instruction code 
    ///   - p1: Parameter 1
    ///   - p2: Parameter 2
    ///   - data: Command data
    ///   - le: Expected response length
    /// - Returns: The response from the passport
    static func sendCustomCommand(
        tagReader: TagReader,
        cla: UInt8,
        ins: UInt8,
        p1: UInt8,
        p2: UInt8,
        data: [UInt8],
        le: Int
    ) async throws -> ResponseAPDU {
        let cmd = NFCISO7816APDU(
            instructionClass: cla, 
            instructionCode: ins, 
            p1Parameter: p1, 
            p2Parameter: p2, 
            data: Data(data), 
            expectedResponseLength: le
        )
        
        return try await tagReader.send(cmd: cmd)
    }
}
