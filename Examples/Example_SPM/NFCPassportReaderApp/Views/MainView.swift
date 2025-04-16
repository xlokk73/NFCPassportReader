//
//  MainView.swift
//  NFCPassportReaderApp
//
//  Created by Andy Qua on 04/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import SwiftUI
import OSLog
import Combine
import NFCPassportReader
import UniformTypeIdentifiers
import MRZParser

let appLogging = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "app")


struct MainView : View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme

    @State private var showingAlert = false
    @State private var showingSheet = false
    @State private var showDetails = false
    @State private var alertTitle : String = ""
    @State private var alertMessage : String = ""
    @State private var showSettings : Bool = false
    @State private var showScanMRZ : Bool = false
    @State private var showSavedPassports : Bool = false
    @State private var gettingLogs : Bool = false

    @State var page = 0
    
    @State var bgColor = Color( UIColor.systemBackground )
    
    private let passportReader = PassportReader()

    var body: some View {
        NavigationView {
            ZStack {
                NavigationLink( destination: SettingsView(), isActive: $showSettings) { Text("") }
                NavigationLink( destination: PassportView(), isActive: $showDetails) { Text("") }
                NavigationLink( destination: StoredPassportView(), isActive: $showSavedPassports) { Text("") }
                NavigationLink( destination: MRZScanner(completionHandler: { mrz in
                    
                    if let (docNr, dob, doe) = parse( mrz:mrz ) {
                        settings.passportNumber = docNr
                        settings.dateOfBirth = dob
                        settings.dateOfExpiry = doe
                    }
                    showScanMRZ = false
                }).navigationTitle("Scan MRZ"), isActive: $showScanMRZ){ Text("") }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: {self.showScanMRZ.toggle()}) {
                            Label("Scan MRZ", systemImage:"camera")
                        }.padding([.top, .trailing])
                    }
                    MRZEntryView()
                    
                    Button(action: {
                        self.scanPassport()
                    }) {
                        Text("Scan Passport")
                            .font(.largeTitle)
                            .foregroundColor(isValid ? .secondary : Color.secondary.opacity(0.25))
                    }
                    .disabled( !isValid )

                    Spacer()
                    HStack(alignment:.firstTextBaseline) {
                        Text( "Version - \(UIApplication.version)" )
                            .font(.footnote)
                            .padding(.leading)
                        Spacer()
                        Button(action: {
                            shareLogs()
                        }) {
                            Text("Share logs")
                                .foregroundColor(.secondary)
                        }.padding(.trailing)
                        .disabled( !isValid )
                    }
                }
                
                if gettingLogs {
                    VStack {
                        VStack(alignment:.center) {
                            Text( "Retrieving logs....." )
                                .font(.title)
                                .frame(maxWidth:.infinity, maxHeight:150)
                        }
                        .shadow(radius: 10)
                        .background(.white)
                        .cornerRadius(20) /// make the background rounded
                        .overlay( /// apply a rounded border
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(.gray, lineWidth: 2)
                        )
                        .padding()
                        Spacer()
                    }
                }
            }
            .navigationBarTitle("Passport details", displayMode: .automatic)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: {showSettings.toggle()}) {
                            Label("Settings", systemImage: "gear")
                        }
                        Button(action: {self.showSavedPassports.toggle()}) {
                            Label("Show saved passports", systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "gear")
                            .foregroundColor(Color.secondary)
                    }
                }
            }
            .alert(isPresented: $showingAlert) {
                    Alert(title: Text(alertTitle), message:
                        Text(alertMessage), dismissButton: .default(Text("Got it!")))
            }
            .background(colorScheme == .dark ? Color.black : Color.white)
        }
    }
}

// MARK: View functions - functions that affect the view
extension MainView {
    
    var isValid : Bool {
        return settings.passportNumber.count >= 8
    }

    func parse( mrz:String ) -> (String, Date, Date)? {
        print( "mrz = \(mrz)")
        
        let parser = MRZParser(isOCRCorrectionEnabled: true)
        if let result = parser.parse(mrzString: mrz),
           let docNr = result.documentNumber,
           let dob = result.birthdate,
           let doe = result.expiryDate {
            
            return (docNr, dob, doe)
        }
        return nil
    }
}

// MARK: Action Functions
extension MainView {

    func shareLogs() {
        gettingLogs = true
        Task {
            hideKeyboard()
            PassportUtils.shareLogs()
            gettingLogs = false
        }
    }

    func scanPassport() {
        lastPassportScanTime = Date.now

        hideKeyboard()
        self.showDetails = false
        
        let df = DateFormatter()
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "YYMMdd"
        
        let pptNr = settings.passportNumber
        let dob = df.string(from:settings.dateOfBirth)
        let doe = df.string(from:settings.dateOfExpiry)
        let useExtendedMode = settings.useExtendedMode

        let passportUtils = PassportUtils()
        let mrzKey = passportUtils.getMRZKey(passportNumber: pptNr, dateOfBirth: dob, dateOfExpiry: doe)
        
        appLogging.error("Using version \(UIApplication.version)")
        
        Task {
            let customMessageHandler: (NFCViewDisplayMessage) -> String? = { (displayMessage) in
                switch displayMessage {
                    case .requestPresentPassport:
                        return "Hold your iPhone near an NFC enabled passport for PACE authentication."
                    default:
                        // Return nil for all other messages so we use the provided default
                        return nil
                }
            }
            
            do {
                // Use the existing passportReader but focus only on PACE
                let passport = try await passportReader.readPassport(
                    mrzKey: mrzKey,
                    tags: [], // Empty array - we'll only read minimal data
                    skipSecureElements: true,
                    skipCA: true,
                    skipPACE: false, // Don't skip PACE - we want to perform it
                    useExtendedMode: useExtendedMode,
                    customDisplayMessage: customMessageHandler
                )
                
                // Check if PACE authentication was successful
                if passport.PACEStatus == .success {
                    // PACE authentication successful
                    self.alertTitle = "Success"
                    self.alertMessage = "PACE authentication successful"
                } else {
                    // PACE authentication failed or not supported
                    self.alertTitle = "Failed"
                    self.alertMessage = "PACE authentication failed or not supported"
                }
                self.showingAlert = true
                
            } catch {
                self.alertTitle = "Error"
                self.alertMessage = error.localizedDescription
                self.showingAlert = true
            }
        }
    }
}

//MARK: PreviewProvider
#if DEBUG
struct ContentView_Previews : PreviewProvider {

    static var previews: some View {
        let settings = SettingsStore()
        
        return Group {
            MainView()
                .environmentObject(settings)
                .environment( \.colorScheme, .light)
            MainView()
                .environmentObject(settings)
                .environment( \.colorScheme, .dark)
        }
    }
}
#endif



