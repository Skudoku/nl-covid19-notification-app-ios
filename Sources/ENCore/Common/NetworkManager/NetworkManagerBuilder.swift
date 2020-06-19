/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import Foundation

/// @mockable
protocol NetworkManaging {

    // MARK: CDN

    func getManifest(completion: @escaping (Result<Manifest, NetworkManagerError>) -> ())
    func getAppConfig(appConfig: String, completion: @escaping (Result<AppConfig, NetworkManagerError>) -> ())
    func getRiskCalculationParameters(appConfig: String, completion: @escaping (Result<RiskCalculationParameters, NetworkManagerError>) -> ())
    func getDiagnosisKeys(_ id: String, completion: @escaping (Result<[URL], NetworkManagerError>) -> ())

    // MARK: Enrollment

    func postRegister(register: RegisterRequest, completion: @escaping (Result<LabInformation, NetworkManagerError>) -> ())
    func postKeys(diagnosisKeys: DiagnosisKeys, completion: @escaping (NetworkManagerError?) -> ())
    func postStopKeys(diagnosisKeys: DiagnosisKeys, completion: @escaping (NetworkManagerError?) -> ())
}



/// @mockable
protocol NetworkManagerBuildable {
    func build() -> NetworkManaging
}

private final class NetworkManagerDependencyProvider: DependencyProvider<EmptyDependency> {
    lazy var networkResponseProvider: NetworkResponseProviderHandling = {
        return NetworkResponseProviderBuilder().build()
    }()
}


final class NetworkManagerBuilder: Builder<EmptyDependency>, NetworkManagerBuildable {
    func build() -> NetworkManaging {
        
        let dependencyProvider = NetworkManagerDependencyProvider(dependency: dependency)
        #if DEBUG
            let configuration: NetworkConfiguration = .development
        #else
            let configuration: NetworkConfiguration = .production
        #endif
        
        return NetworkManager(configuration: configuration, networkResponseHandler: dependencyProvider.networkResponseProvider)
    }
}
