/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import Combine
import Foundation
import UIKit

private struct ExposureKeySetDetectionResult {
    let keySetHolder: ExposureKeySetHolder
    let exposureSummary: ExposureDetectionSummary?
    let processedCorrectly: Bool
    let exposureReport: ExposureReport?
}

private struct ExposureDetectionResult {
    let keySetDetectionResults: [ExposureKeySetDetectionResult]
    let exposureSummary: ExposureDetectionSummary?
}

struct ExposureReport: Codable {
    let date: Date
    let duration: TimeInterval?
}

final class ProcessExposureKeySetsDataOperation: ExposureDataOperation, Logging {

    init(networkController: NetworkControlling,
         storageController: StorageControlling,
         exposureManager: ExposureManaging,
         configuration: ExposureConfiguration) {
        self.networkController = networkController
        self.storageController = storageController
        self.exposureManager = exposureManager
        self.configuration = configuration
    }

    func execute() -> AnyPublisher<(), ExposureDataError> {
        self.logDebug("--- START PROCESSING KEYSETS ---")

        // get all keySets that have not been processed before
        let exposureKeySets = getStoredKeySetsHolders()
            .filter { $0.processed == false }

        // convert all exposureKeySets into streams which emit detection reports
        let exposures = exposureKeySets.map {
            self.detectExposures(for: $0)
                .eraseToAnyPublisher()
        }

        if exposures.count > 0 {
            logDebug("Processing KeySets: \(exposureKeySets.map { $0.identifier }.joined(separator: "\n"))")
        } else {
            logDebug("No additional keysets to process")
        }

        // Combine all streams into an array of streams
        return Publishers.Sequence<[AnyPublisher<ExposureKeySetDetectionResult, ExposureDataError>], ExposureDataError>(sequence: exposures)
            // execute them one by one
            .flatMap(maxPublishers: .max(1)) { $0 }
            // wait until all of them are done and collect them in an array again
            .collect()
            // select an exposure summary from the results
            .map { results in
                self.selectExposureSummaryFrom(results: results, configuration: self.configuration)
            }
            // persist keySetHolders in local storage to remember which ones have been processed correctly
            .flatMap(self.persistResult(_:))
            // create an exposureReport and trigger a local notification
            .flatMap(self.createReportAndTriggerNotification(forResult:))
            // persist the ExposureReport
            .flatMap(self.persist(exposureReport:))
            // update last processing date
            .flatMap(self.updateLastProcessingDate)
            // remove all blobs for all keySetHolders - successful ones are processed and
            // should not be processed again. Failed ones should be downloaded again and
            // have already been removed from the list of keySetHolders in localStorage by persistResult(_:)
            .handleEvents(receiveOutput: removeBlobs(forResult:))
            // ignore result
            .map { _ in () }
            .handleEvents(
                receiveCompletion: { _ in self.logDebug("--- END PROCESSING KEYSETS ---") },
                receiveCancel: { self.logDebug("--- PROCESSING KEYSETS CANCELLED ---") }
            )
            .share()
            .eraseToAnyPublisher()
    }

    // MARK: - Private

    /// Retrieves all stores keySetHolders from local storage
    private func getStoredKeySetsHolders() -> [ExposureKeySetHolder] {
        return storageController.retrieveObject(identifiedBy: ExposureDataStorageKey.exposureKeySetsHolders) ?? []
    }

    /// Verifies whether the KeySetHolder URLs point to valid files
    private func verifyLocalFileUrl(forKeySetsHolder keySetHolder: ExposureKeySetHolder) -> Bool {
        var isDirectory = ObjCBool(booleanLiteral: false)

        // verify export.sig and export.bin are present
        guard FileManager.default.fileExists(atPath: keySetHolder.signatureFileUrl.path, isDirectory: &isDirectory), isDirectory.boolValue == false else {
            return false
        }

        guard FileManager.default.fileExists(atPath: keySetHolder.binaryFileUrl.path, isDirectory: &isDirectory), isDirectory.boolValue == false else {
            return false
        }

        return true
    }

    /// Returns ExposureKeySetDetectionResult in case of a success, or in case of an error that's
    /// not related to the framework's inactiveness. When an error is thrown from here exposure detection
    /// should be stopped until the user enables the framework
    private func detectExposures(for keySetHolder: ExposureKeySetHolder) -> AnyPublisher<ExposureKeySetDetectionResult, ExposureDataError> {
        return Deferred {
            Future { promise in
                if self.verifyLocalFileUrl(forKeySetsHolder: keySetHolder) == false {
                    // mark it as processed incorrectly - will be downloaded again
                    // next time
                    let result = ExposureKeySetDetectionResult(keySetHolder: keySetHolder,
                                                               exposureSummary: nil,
                                                               processedCorrectly: false,
                                                               exposureReport: nil)
                    self.logDebug("Missing local files for \(keySetHolder.identifier)")
                    promise(.success(result))
                    return
                }

                let diagnosisKeyURLs = [keySetHolder.signatureFileUrl, keySetHolder.binaryFileUrl]

                self.exposureManager.detectExposures(configuration: self.configuration,
                                                     diagnosisKeyURLs: diagnosisKeyURLs) { result in
                    switch result {
                    case let .success(summary):
                        self.logDebug("Success for \(keySetHolder.identifier): \(String(describing: summary))")

                        promise(.success(ExposureKeySetDetectionResult(keySetHolder: keySetHolder,
                                                                       exposureSummary: summary,
                                                                       processedCorrectly: true,
                                                                       exposureReport: nil)))
                    case let .failure(error):
                        self.logDebug("Failure for \(keySetHolder.identifier): \(error)")

                        switch error {
                        case .bluetoothOff, .disabled, .notAuthorized, .restricted:
                            promise(.failure(error.asExposureDataError))
                        case .internalTypeMismatch:
                            promise(.failure(.internalError))
                        default:
                            promise(.success(ExposureKeySetDetectionResult(keySetHolder: keySetHolder,
                                                                           exposureSummary: nil,
                                                                           processedCorrectly: false,
                                                                           exposureReport: nil)))
                        }
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    /// Updates the local keySetHolder storage with the latest results
    private func persistResult(_ result: ExposureDetectionResult) -> AnyPublisher<ExposureDetectionResult, ExposureDataError> {
        return Deferred {
            Future { promise in
                let selectKeySetDetectionResult: (ExposureKeySetHolder) -> ExposureKeySetDetectionResult? = { keySetHolder in
                    // find result that belongs to the keySetHolder
                    result.keySetDetectionResults.first { result in result.keySetHolder.identifier == keySetHolder.identifier }
                }

                self.storageController.requestExclusiveAccess { storageController in
                    let storedKeySetHolders = storageController.retrieveObject(identifiedBy: ExposureDataStorageKey.exposureKeySetsHolders) ?? []
                    var keySetHolders: [ExposureKeySetHolder] = []

                    storedKeySetHolders.forEach { keySetHolder in
                        guard let result = selectKeySetDetectionResult(keySetHolder) else {
                            // no result for this one, just append and process it next time
                            keySetHolders.append(keySetHolder)
                            return
                        }

                        if result.processedCorrectly {
                            // only store correctly processed results - forget about incorrectly processed ones
                            // and try to download those again next time
                            keySetHolders.append(ExposureKeySetHolder(identifier: keySetHolder.identifier,
                                                                      signatureFileUrl: keySetHolder.signatureFileUrl,
                                                                      binaryFileUrl: keySetHolder.binaryFileUrl,
                                                                      processed: true,
                                                                      creationDate: keySetHolder.creationDate))
                        }
                    }

                    storageController.store(object: keySetHolders,
                                            identifiedBy: ExposureDataStorageKey.exposureKeySetsHolders) { _ in
                        promise(.success(result))
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    /// Removes binary files for the keySetHolders of the exposureDetectionResult
    private func removeBlobs(forResult exposureResult: (ExposureDetectionResult, ExposureReport?)) {
        let keySetHolders = exposureResult.0.keySetDetectionResults.map { $0.keySetHolder }

        keySetHolders.forEach { keySetHolder in
            try? FileManager.default.removeItem(at: keySetHolder.signatureFileUrl)
            try? FileManager.default.removeItem(at: keySetHolder.binaryFileUrl)
        }
    }

    /// Select a most recent exposure summary
    private func selectExposureSummaryFrom(results: [ExposureKeySetDetectionResult],
                                           configuration: ExposureConfiguration) -> ExposureDetectionResult {
        logDebug("Picking the correct summary from \(results.count) results")

        // filter out unprocessed results
        let summaries = results
            .filter { $0.processedCorrectly }
            .compactMap { $0.exposureSummary }
            .filter { $0.maximumRiskScore >= configuration.minimumRiskScope }
            .filter { $0.matchedKeyCount > 0 }

        logDebug("Filtered based on maximumRiskScore, matchedKeyCount and processedCorrectly: \(summaries.count) results left")

        // find most recent exposure day
        guard let mostRecentDaysSinceLastExposure = summaries
            .sorted(by: { $1.daysSinceLastExposure < $0.daysSinceLastExposure })
            .last?
            .daysSinceLastExposure
        else {
            logDebug("Cannot find most recent days since last exposure")

            return ExposureDetectionResult(keySetDetectionResults: results,
                                           exposureSummary: nil)
        }

        logDebug("Most recent days since last exposure: \(mostRecentDaysSinceLastExposure)")

        // take only most recent exposures and select first (doesn't matter which one)
        let summary = summaries
            .filter { $0.daysSinceLastExposure == mostRecentDaysSinceLastExposure }
            .first

        logDebug("Final summary: \(String(describing: summary))")

        return ExposureDetectionResult(keySetDetectionResults: results,
                                       exposureSummary: summary)
    }

    /// Creates the final ExposureReport and triggers a local notification using the EN framework
    private func createReportAndTriggerNotification(forResult result: ExposureDetectionResult) -> AnyPublisher<(ExposureDetectionResult, ExposureReport?), ExposureDataError> {

        logDebug("Triggering local notification")

        guard let summary = result.exposureSummary else {
            logDebug("No summary to trigger notification for")
            return Just((result, nil))
                .setFailureType(to: ExposureDataError.self)
                .eraseToAnyPublisher()
        }

        logDebug("Triggering notification for \(summary)")

        return self
            .getExposureInformations(forSummary: summary,
                                     userExplanation: .exposureNotificationUserExplanation)
            .map { (exposureInformations) -> (ExposureDetectionResult, ExposureReport?) in
                self.logDebug("Got back exposure info \(String(describing: exposureInformations))")

                // get most recent exposureInformation
                guard let exposureInformation = self.getLastExposureInformation(for: exposureInformations) else {
                    self.logDebug("Cannot get last exposure info")

                    return (result, nil)
                }

                let exposureReport = ExposureReport(date: exposureInformation.date,
                                                    duration: exposureInformation.duration)

                self.logDebug("Final exposure report: \(exposureReport)")

                return (result, exposureReport)
            }
            .eraseToAnyPublisher()
    }

    /// Asks the EN framework for more information about the exposure summary which
    /// triggers a local notification if the exposure was risky enough (according to the configuration and
    /// the rules of the EN framework)
    private func getExposureInformations(forSummary summary: ExposureDetectionSummary?, userExplanation: String) -> AnyPublisher<[ExposureInformation]?, ExposureDataError> {
        guard let summary = summary else {
            return Just(nil).setFailureType(to: ExposureDataError.self).eraseToAnyPublisher()
        }

        return Deferred {
            Future<[ExposureInformation]?, ExposureDataError> { promise in
                self.exposureManager
                    .getExposureInfo(summary: summary,
                                     userExplanation: userExplanation) { infos, error in
                        if let error = error {
                            promise(.failure(error.asExposureDataError))
                            return
                        }

                        promise(.success(infos))
                    }
            }
            .subscribe(on: DispatchQueue.main)
        }
        .eraseToAnyPublisher()
    }

    /// Returns the exposureInformation with the most recent date
    private func getLastExposureInformation(for informations: [ExposureInformation]?) -> ExposureInformation? {
        guard let informations = informations else { return nil }

        let isNewer: (ExposureInformation, ExposureInformation) -> Bool = { first, second in
            return second.date > first.date
        }

        return informations.sorted(by: isNewer).last
    }

    /// Stores the exposureReport in local storage (which triggers the 'notified' state)
    private func persist(exposureReport value: (ExposureDetectionResult, ExposureReport?)) -> AnyPublisher<(ExposureDetectionResult, ExposureReport?), ExposureDataError> {
        return Deferred {
            Future { promise in
                guard let exposureReport = value.1 else {
                    promise(.success(value))
                    return
                }

                self.storageController.requestExclusiveAccess { storageController in
                    let lastExposureReport = storageController.retrieveObject(identifiedBy: ExposureDataStorageKey.lastExposureReport)

                    if let lastExposureReport = lastExposureReport, lastExposureReport.date > exposureReport.date {
                        // already stored a newer report, ignore this one
                        promise(.success(value))
                    } else {
                        // store the new report
                        storageController.store(object: exposureReport,
                                                identifiedBy: ExposureDataStorageKey.lastExposureReport) { _ in
                            promise(.success(value))
                        }
                    }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    /// Updates the date when this operation has last run
    private func updateLastProcessingDate(_ value: (ExposureDetectionResult, ExposureReport?)) -> AnyPublisher<(ExposureDetectionResult, ExposureReport?), ExposureDataError> {
        return Deferred {
            Future { promise in
                self.storageController.requestExclusiveAccess { storageController in
                    let date = Date()

                    storageController.store(object: date,
                                            identifiedBy: ExposureDataStorageKey.lastExposureProcessingDate,
                                            completion: { _ in
                                                promise(.success(value))
                    })
                }
            }
        }
        .eraseToAnyPublisher()
    }

    private let networkController: NetworkControlling
    private let storageController: StorageControlling
    private let exposureManager: ExposureManaging
    private let configuration: ExposureConfiguration
}
