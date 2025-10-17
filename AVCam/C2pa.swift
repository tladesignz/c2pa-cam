//
//  C2pa.swift
//  c2pa-cam
//
//  Created by Benjamin Erhart on 17.10.25.
//  Copyright © 2025 Apple. All rights reserved.
//

import Foundation
import C2PA
import OSLog
import CoreMedia
import UniformTypeIdentifiers
import ImageIO

class C2pa {

    static let shared = C2pa()


    private let signerInfo: SignerInfo

    private lazy var logger = Logger(subsystem: String(describing: type(of: self)), category: "c2pa")


    init() {
        var cert = ""

        if let url = Bundle.main.url(forResource: "es256_certs", withExtension: "pem") {
            cert = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        var key = ""

        if let url = Bundle.main.url(forResource: "es256_private", withExtension: "key") {
            key = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        signerInfo = SignerInfo(algorithm: .es256, certificatePEM: cert, privateKeyPEM: key)
    }


    @MainActor
    func sign(_ photo: Photo) -> Photo {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let manifest = createManifest(photo.uti, photo.timestamp.date)
        else {
            return photo
        }

        print(manifest.description)

        let outputUrl = cacheDir.appendingPathComponent(manifest.title)
        let outputMovieUrl: URL?

        do {
            try sign(photo.data, with: manifest, to: outputUrl)

            if let liveMovieUrl = photo.livePhotoMovieURL,
               let uti = liveMovieUrl.contentType,
               let manifest = createManifest(uti, photo.timestamp.date)
            {
                print(manifest.description)

                outputMovieUrl = cacheDir.appendingPathComponent(manifest.title)

                try sign(liveMovieUrl, with: manifest, to: outputMovieUrl!)
            }
            else {
                outputMovieUrl = nil
            }

            let newPhoto = Photo(data: try Data(contentsOf: outputUrl, options: .uncached),
                                 livePhotoMovieUrl: outputMovieUrl ?? photo.livePhotoMovieURL,
                                 timestamp: photo.timestamp)

            try? FileManager.default.removeItem(at: outputUrl)

            return newPhoto
        }
        catch {
            logger.error("\(error)")

            try? FileManager.default.removeItem(at: outputUrl)

            return photo
        }
    }

    @MainActor
    func sign(_ movie: Movie) -> Movie {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let manifest = createManifest(movie.url.contentType, movie.url.modifiedDate)
        else {
            return movie
        }

        print(manifest.description)

        let outputUrl = cacheDir.appendingPathComponent(manifest.title)

        do {
            try sign(movie.url, with: manifest, to: outputUrl)

            let newMovie = Movie(url: outputUrl)

            try? FileManager.default.removeItem(at: movie.url)

            return newMovie
        }
        catch {
            logger.error("\(error)")

            try? FileManager.default.removeItem(at: outputUrl)

            return movie
        }
    }


    // MARK: Private Methods

    @MainActor
    private func createManifest(_ uti: UTType?, _ timestamp: Date?) -> ManifestDefinition? {
        guard let uti = uti,
              let mimeType = uti.preferredMIMEType,
              let ext = uti.preferredFilenameExtension,
              let timestamp = timestamp
        else {
            return nil
        }

        return ManifestDefinition(
            assertions: [.actions(actions: [Action(action: .created, digitalSourceType: .digitalCapture)])],
            claimGeneratorInfo: [.init(operatingSystem: ClaimGeneratorInfo.operatingSystem)],
            format: mimeType,
            title: String(format: "c2pa-cam_%@.%@", timestamp.iso8601, ext))
    }

    private func sign(_ source: Data, with manifest: ManifestDefinition, to dest: URL) throws {
        try Builder(manifestJSON: manifest.description).sign(
            format: manifest.format,
            source: try Stream(data: source),
            destination: try Stream(fileURL: dest),
            signer: try Signer(info: signerInfo))
    }

    private func sign(_ source: URL, with manifest: ManifestDefinition, to dest: URL) throws {
        try Builder(manifestJSON: manifest.description).sign(
            format: manifest.format,
            source: try Stream(fileURL: source, truncate: false, createIfNeeded: false),
            destination: try Stream(fileURL: dest),
            signer: try Signer(info: signerInfo))
    }
}

fileprivate extension Photo {

    var uti: UTType? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let uti = CGImageSourceGetType(source)
        {
            return UTType(uti as String)
        }

        return nil
    }


    init(data: Data, livePhotoMovieUrl: URL? = nil, timestamp: CMTime) {
        self.data = data
        isProxy = false
        livePhotoMovieURL = livePhotoMovieUrl
        self.timestamp = timestamp
    }
}

fileprivate extension CMTime {

    var date: Date {
        Date().addingTimeInterval(seconds - CMClockGetHostTimeClock().time.seconds)
    }
}

fileprivate extension Date {

    var iso8601: String {
        ISO8601DateFormatter
            .string(from: self, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
            .replacingOccurrences(of: ":", with: ".")
    }
}

fileprivate extension URL {

    var contentType: UTType? {
        try? resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    var modifiedDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
