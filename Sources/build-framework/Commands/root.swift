import Foundation
import System

import ArgumentParser
import CLTLogger
import Logging
import XcodeTools
import XibLoc



@main
struct BuildFramework : ParsableCommand {
	
	@Option(help: "The path to the “Files” directory, containing some resources to build OpenLDAP.")
	var filesPath = Self.defaultFilesFolderURL.path
	
	@Option(help: "Everything build-framework will create will be in this folder, except the final xcframeworks. The folder will be created if it does not exist.")
	var workdir = "./openldap-workdir"
	
	@Option(help: "The final xcframeworks will be in this folder. If unset, will be equal to the work dir. The folder will be created if it does not exist.")
	var resultdir: String?
	
	@Option(help: "The base URL from which to download OpenLDAP. Everything between double curly braces “{{}}” will be replaced by the OpenLDAP version to build.")
	var openldapBaseURL = "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-{{ version }}.tgz"
	
	@Option
	var openldapVersion = "2.5.5"
	
	/* For 2.5.5, value is 74ecefda2afc0e054d2c7dc29166be6587fa9de7a4087a80183bc9c719dbf6b3 */
	@Option(help: "The shasum-256 expected for the tarball. If not set, the integrity of the archive will not be verified.")
	var expectedTarballShasum: String?
	
	@Option(name: .customLong("openssl-xcframework-url"), help: "The URL to the OpenSSL dynamic XCFramework archive (zip format). The URL scheme can be file, http or https. A file URL can either point to an XCFramework archive or an XCFramework directly.")
	var opensslXCFrameworkURL: URL
	
	@Option(name: .customLong("expected-openssl-xcframework-shasum"), help: "The shasum-256 expected for the OpenSSL XCFramework archive. If the URL points to an unarchived XCFramework, this option is ignored.")
	var expectedOpenSSLXCFrameworkShasum: String?
	
	@Flag
	var disableBitcode = false
	
	@Flag
	var clean = false
	
	@Flag
	var skipExistingArtifacts = false
	
	@Option
	var targets = [
		Target(sdk: "macOS", platform: "macOS", arch: "arm64"),
		Target(sdk: "macOS", platform: "macOS", arch: "x86_64")
		/* libsasl2 is not available on Apple platforms other than macOS. */
	]
	
	@Option(name: .customLong("macos-sdk-version"))
	var macOSSDKVersion: String?
	
	@Option(name: .customLong("macos-min-sdk-version"))
	var macOSMinSDKVersion: String?
	
	@Option(name: .customLong("ios-sdk-version"))
	var iOSSDKVersion: String?
	
	@Option(name: .customLong("ios-min-sdk-version"))
	var iOSMinSDKVersion: String?
	
	@Option
	var catalystSDKVersion: String?
	
	@Option
	var catalystMinSDKVersion: String?
	
	@Option(name: .customLong("watchos-sdk-version"))
	var watchOSSDKVersion: String?
	
	@Option(name: .customLong("watchos-min-sdk-version"))
	var watchOSMinSDKVersion: String?
	
	@Option(name: .customLong("tvos-sdk-version"))
	var tvOSSDKVersion: String?
	
	@Option(name: .customLong("tvos-min-sdk-version"))
	var tvOSMinSDKVersion: String?
	
	func run() async throws {
		LoggingSystem.bootstrap{ _ in CLTLogger() }
		XcodeTools.XcodeToolsConfig.logger?.logLevel = .warning
		
		let opensslFramework = try XCFrameworkDependencySource(url: opensslXCFrameworkURL, expectedShasum: expectedOpenSSLXCFrameworkShasum, skipExistingArtifacts: skipExistingArtifacts)
		let buildPaths = try BuildPaths(filesPath: FilePath(filesPath), workdir: FilePath(workdir), resultdir: resultdir.flatMap{ FilePath($0) }, productName: "COpenLDAP", opensslFramework: opensslFramework)
		
		if clean {
			Config.logger.info("Cleaning previous builds if applicable")
			try buildPaths.clean()
		}
		try buildPaths.ensureAllDirectoriesExist()
		
		let opensslXCFramework = try await opensslFramework.downloadAndExtract(in: buildPaths.workDir)
		Config.logger.trace("Parsed OpenSSL XCFramework: \(opensslXCFramework)")
		
		let tarball = try Tarball(templateURL: openldapBaseURL, version: openldapVersion, downloadFolder: buildPaths.workDir, expectedShasum: expectedTarballShasum)
		try await tarball.ensureDownloaded()
		
		/* Build all the variants we need. Note only static libs are built because
		 * we merge them later in a single dyn lib to create a single framework. */
		var dylibs = [Target: FilePath]()
		var builtTargets = [Target: BuiltTarget]()
		for target in targets {
			let sdkVersion: String
			let minSDKVersion: String?
			switch (target.sdk, target.platform) {
				case ("iOS", "macOS"): (sdkVersion, minSDKVersion) = try (catalystSDKVersion ?? Process.spawnAndGetOutput("/usr/bin/xcrun", args: ["-sdk", "macosx",    "--show-sdk-version"]).trimmingCharacters(in: .whitespacesAndNewlines), catalystMinSDKVersion ?? Process.spawnAndGetOutput("/usr/bin/xcrun", args: ["-sdk", "iphoneos",  "--show-sdk-version"]).trimmingCharacters(in: .whitespacesAndNewlines))
				case ("macOS", _):     (sdkVersion, minSDKVersion) = try (   macOSSDKVersion ?? Process.spawnAndGetOutput("/usr/bin/xcrun", args: ["-sdk", "macosx",    "--show-sdk-version"]).trimmingCharacters(in: .whitespacesAndNewlines),    macOSMinSDKVersion)
				case ("iOS", _):       (sdkVersion, minSDKVersion) = try (     iOSSDKVersion ?? Process.spawnAndGetOutput("/usr/bin/xcrun", args: ["-sdk", "iphoneos",  "--show-sdk-version"]).trimmingCharacters(in: .whitespacesAndNewlines),      iOSMinSDKVersion)
				case ("tvOS", _):      (sdkVersion, minSDKVersion) = try (    tvOSSDKVersion ?? Process.spawnAndGetOutput("/usr/bin/xcrun", args: ["-sdk", "appletvos", "--show-sdk-version"]).trimmingCharacters(in: .whitespacesAndNewlines),     tvOSMinSDKVersion)
				case ("watchOS", _):   (sdkVersion, minSDKVersion) = try ( watchOSSDKVersion ?? Process.spawnAndGetOutput("/usr/bin/xcrun", args: ["-sdk", "watchos",   "--show-sdk-version"]).trimmingCharacters(in: .whitespacesAndNewlines),  watchOSMinSDKVersion)
				default:
					Config.logger.warning("Unknown target sdk/platform tuple \(target.sdk)/\(target.platform)")
					(sdkVersion, minSDKVersion) = ("1.0", nil)
			}
			
			guard let frameworkPath = opensslXCFramework.frameworkPath(forTarget: target) else {
				struct NoFrameworkForTargetInXCFrameworkDependency : Error {var target: Target}
				throw NoFrameworkForTargetInXCFrameworkDependency(target: target)
			}
			
			let unbuiltTarget = UnbuiltTarget(target: target, tarball: tarball, buildPaths: buildPaths, opensslFrameworkName: opensslXCFramework.frameworksName, opensslFrameworkPath: frameworkPath, sdkVersion: sdkVersion, minSDKVersion: minSDKVersion, openldapVersion: openldapVersion, disableBitcode: disableBitcode, skipExistingArtifacts: skipExistingArtifacts)
			let builtTarget = try unbuiltTarget.buildTarget()
			
			assert(builtTargets[target] == nil)
			builtTargets[target] = builtTarget
			
			assert(dylibs[target] == nil)
			dylibs[target] = try builtTarget.buildDylibFromStaticLibs(openldapVersion: openldapVersion, buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts)
		}
		
		let targetsByPlatformAndSdks = Dictionary(grouping: targets, by: { PlatformAndSdk(platform: $0.platform, sdk: $0.sdk) })
		
		/* Create all the frameworks and related needed to create the final static
		 * and dynamic xcframeworks. */
		var frameworks = [FilePath]()
		var librariesAndHeadersDir = [(library: FilePath, headersDir: FilePath)]()
		for (platformAndSdk, targets) in targetsByPlatformAndSdks {
			let firstTarget = targets.first! /* Safe because of the way targetsByPlatformAndSdks is built. */
			
			/* First let’s check all targets have the same headers and libs for
			 * this platform/sdk tuple, and also check all libs have the same
			 * bitcode status. */
			let builtTarget = builtTargets[firstTarget]! /* Safe because of the way builtTargets is built. */
			for target in targets {
				let currentBuiltTarget = builtTargets[target]! /* Safe because of the way builtTargets is built. */
				guard builtTarget.headers == currentBuiltTarget.headers else {
					struct IncompatibleHeadersBetweenTargetsForSamePlatformAndSdk : Error {
						var refTarget: Target
						var refHeaders: [FilePath]
						var currentTarget: Target
						var currentHeaders: [FilePath]
					}
					throw IncompatibleHeadersBetweenTargetsForSamePlatformAndSdk(
						refTarget: firstTarget, refHeaders: builtTarget.headers,
						currentTarget: target, currentHeaders: currentBuiltTarget.headers
					)
				}
				guard builtTarget.staticLibraries == currentBuiltTarget.staticLibraries else {
					struct IncompatibleLibsBetweenTargetsForSamePlatformAndSdk : Error {
						var refTarget: Target
						var refLibs: [FilePath]
						var currentTarget: Target
						var currentLibs: [FilePath]
					}
					throw IncompatibleLibsBetweenTargetsForSamePlatformAndSdk(
						refTarget: firstTarget, refLibs: builtTarget.staticLibraries,
						currentTarget: target, currentLibs: currentBuiltTarget.staticLibraries
					)
				}
			}
			
			/* Merge the headers and drop the “include” path component. */
			var mergedHeaders = [FilePath]()
			for header in builtTarget.headers {
				/* Correct way to do this is lines below, but crashes for now. */
//				guard header.components.starts(with: ["include"]) else {
//					Config.logger.warning("Got a header not in “include” dir. Skipping.")
//					continue
//				}
//				let headerNoInclude = FilePath(root: nil, header.components.dropFirst(2))
				guard header.string.starts(with: "include/") else {
					Config.logger.warning("Got a header not in “include” dir. Skipping.")
					continue
				}
				let headerNoInclude = FilePath(String(header.string.dropFirst("include/".count)))
				var unmergedHeader = UnmergedUnpatchedHeader(
					headersAndArchs: targets.map{ (buildPaths.installDir(for: $0).pushing(header), $0.arch) },
					patches: [
						{ filepath, str in
							guard filepath.lastComponent == "ldif.h" else {return str}
							let searched = "#include <ldap_cdefs.h>\n"
							let replacement = searched + "#include <stdio.h>\n"
							return str.replacingOccurrences(of: searched, with: replacement, options: .literal)
						},
						{ _, str in
							var str = str
							for header in builtTarget.headers {
								guard let headerName = header.lastComponent else {continue}
								let searched = "<\(headerName)>"
								let replacement = "<\(buildPaths.productName)/\(headerName)>"
								str = str.replacingOccurrences(of: searched, with: replacement, options: .literal)
							}
							return str
						}
					],
					skipExistingArtifacts: skipExistingArtifacts
				)
				try unmergedHeader.patchAndMergeHeaders(at: buildPaths.mergedDynamicHeadersDir.appending(platformAndSdk.pathComponent).pushing(headerNoInclude))
				
				unmergedHeader.patches.removeLast()
				try unmergedHeader.patchAndMergeHeaders(at: buildPaths.mergedStaticHeadersDir.appending(platformAndSdk.pathComponent).pushing(headerNoInclude))
				mergedHeaders.append(headerNoInclude)
			}
			/* Create the umbrella header for the dynamic framework. */
			let dynamicUmbrellaHeader: FilePath
			do {
				let unbuiltUmbrellaHeader = UnbuiltUmbrellaHeader(headers: mergedHeaders, productName: buildPaths.productName, modularImports: true, skipExistingArtifacts: skipExistingArtifacts)
				dynamicUmbrellaHeader = FilePath(buildPaths.productName + ".h")
				try unbuiltUmbrellaHeader.buildUmbrellaHeader(at: buildPaths.mergedDynamicHeadersDir.appending(platformAndSdk.pathComponent).pushing(dynamicUmbrellaHeader))
			}
			/* Create the umbrella header for the dynamic framework. */
			let staticUmbrellaHeader: FilePath
			do {
				let unbuiltUmbrellaHeader = UnbuiltUmbrellaHeader(headers: mergedHeaders, productName: buildPaths.productName, modularImports: false, skipExistingArtifacts: skipExistingArtifacts)
				staticUmbrellaHeader = FilePath(buildPaths.productName + ".h")
				try unbuiltUmbrellaHeader.buildUmbrellaHeader(at: buildPaths.mergedStaticHeadersDir.appending(platformAndSdk.pathComponent).pushing(staticUmbrellaHeader))
			}
			
			/* Create FAT static libs, one per lib */
			var fatStaticLibs = [FilePath]()
			for lib in builtTarget.staticLibraries {
				let unbuiltFATLib = UnbuiltFATLib(libs: targets.map{ buildPaths.installDir(for: $0).pushing(lib) }, skipExistingArtifacts: skipExistingArtifacts)
				let dest = buildPaths.fatStaticDir.appending(platformAndSdk.pathComponent).pushing(lib)
				try unbuiltFATLib.buildFATLib(at: dest)
				fatStaticLibs.append(dest)
			}
			
			/* Create merged FAT static lib */
			let fatStaticLib: FilePath
			do {
				let unbuiltMergedStaticLib = UnbuiltMergedStaticLib(libs: fatStaticLibs, skipExistingArtifacts: skipExistingArtifacts)
				fatStaticLib = buildPaths.mergedFatStaticLibsDir.appending(platformAndSdk.pathComponent).appending(buildPaths.staticLibProductNameComponent)
				try unbuiltMergedStaticLib.buildMergedLib(at: fatStaticLib)
			}
			
			/* Install the module.modulemap file for the static lib */
			do {
				let destPath = buildPaths.mergedStaticHeadersDir.appending(platformAndSdk.pathComponent).appending("module.modulemap")
				if skipExistingArtifacts && Config.fm.fileExists(atPath: destPath.string) {
					Config.logger.info("Skipping creation of \(destPath) because it already exists")
				} else {
					try Config.fm.ensureFileDeleted(path: destPath)
					try Config.fm.ensureDirectory(path: destPath.removingLastComponent())
					let filecontent = try String(contentsOf: buildPaths.templatesDir.appending("static-lib/module.modulemap.xibloc").url)
					try filecontent.applying(xibLocInfo: Str2StrXibLocInfo(replacements: ["|": buildPaths.productName])!)
						.write(to: destPath.url, atomically: false, encoding: .utf8)
				}
			}
			
			/* Let’s copy the static stuff to the final folder. */
			let staticLibAndHeaders: (library: FilePath, headersDir: FilePath)
			do {
				staticLibAndHeaders = (
					buildPaths.finalStaticLibsAndHeadersDir.appending(platformAndSdk.pathComponent).appending(buildPaths.staticLibProductNameComponent),
					buildPaths.finalStaticLibsAndHeadersDir.appending(platformAndSdk.pathComponent).appending("include")
				)
				if skipExistingArtifacts && Config.fm.fileExists(atPath: staticLibAndHeaders.library.string) && Config.fm.fileExists(atPath: staticLibAndHeaders.headersDir.string) {
					Config.logger.info("Skipping creation of \(staticLibAndHeaders) because it already exists")
				} else {
					try Config.fm.ensureFileDeleted(path: staticLibAndHeaders.library)
					try Config.fm.ensureDirectoryDeleted(path: staticLibAndHeaders.headersDir)
					try Config.fm.ensureDirectory(path: staticLibAndHeaders.library.removingLastComponent())
					try Config.fm.ensureDirectory(path: staticLibAndHeaders.headersDir.removingLastComponent())
					
					try Config.fm.copyItem(at: fatStaticLib.url, to: staticLibAndHeaders.library.url)
					try Config.fm.copyItem(at: buildPaths.mergedStaticHeadersDir.appending(platformAndSdk.pathComponent).url, to: staticLibAndHeaders.headersDir.url)
				}
			}
			librariesAndHeadersDir.append(staticLibAndHeaders)
			
			/* Create FAT dylib from the dylibs generated earlier */
			let fatDynamicLib: FilePath
			do {
				let unbuiltFATLib = UnbuiltFATLib(libs: targets.map{ buildPaths.dylibsDir(for: $0).appending(buildPaths.dylibProductNameComponent) }, skipExistingArtifacts: skipExistingArtifacts)
				fatDynamicLib = buildPaths.mergedFatDynamicLibsDir.appending(platformAndSdk.pathComponent).appending(buildPaths.dylibProductNameComponent)
				try unbuiltFATLib.buildFATLib(at: fatDynamicLib)
			}
			
			/* Create the framework from the dylib, headers, and other templates. */
			let frameworkPath: FilePath
			do {
				let frameworkVersion = (platformAndSdk.platform == "macOS" ? "A" : nil)
				/* Some sdk+platform libs might have a more than one min sdk inside
				 * because they have some archs that are not compatible with the min
				 * iOS version (e.g. arm64e is only able to target iOS 14.0 at the
				 * minimum, but arm64 can target lower OSes; if the minimum iOS SDK
				 * is set to something lower than iOS 14.0, the lib for the iOS-iOS
				 * tuple will contain more than one minSdk version).
				 * We decide to give the minimum min sdk (more permissive option)
				 * instead of the maximum min sdk (more conservative option) as the
				 * lib should work on iOS < 14.0, even for such cases (the arm64
				 * slice would be used even on arm64e-capable processor, I think). */
				let minimumOSVersion = try BuiltTarget.getSdkVersions([fatDynamicLib], multipleSdkVersionsResolution: .returnMin).minSdk
				let unbuiltFramework = UnbuiltFramework(
					version: frameworkVersion,
					info: .init(
						platform: platformAndSdk.platform,
						executable: buildPaths.productName,
						identifier: "com.xcode-actions." + buildPaths.productName /* TODO */,
						name: buildPaths.productName,
						marketingVersion: BuiltTarget.normalizedOpenLDAPVersion(openldapVersion),
						buildVersion: "1",
						minimumOSVersion: minimumOSVersion
					),
					libPath: fatDynamicLib,
					headers: (
						mergedHeaders.map{ (root: buildPaths.mergedDynamicHeadersDir.appending(platformAndSdk.pathComponent), file: $0) } +
						[(root: buildPaths.mergedDynamicHeadersDir.appending(platformAndSdk.pathComponent), file: dynamicUmbrellaHeader)]
					),
					modules: [(root: buildPaths.templatesDir.appending("dynamic-lib"), file: "module.modulemap.xibloc")],
					resources: [],
					skipExistingArtifacts: skipExistingArtifacts
				)
				frameworkPath = buildPaths.finalFrameworksDir.appending(platformAndSdk.pathComponent).appending(buildPaths.frameworkProductNameComponent)
				try unbuiltFramework.buildFramework(at: frameworkPath)
			}
			frameworks.append(frameworkPath)
		}
		
		/* Build the static XCFramework */
		do {
			let unbuiltXCFramework = UnbuiltStaticXCFramework(librariesAndHeadersDir: librariesAndHeadersDir, skipExistingArtifacts: skipExistingArtifacts)
			try unbuiltXCFramework.buildXCFramework(at: buildPaths.resultXCFrameworkStatic)
		}
		
		/* Build the dynamic XCFramework */
		do {
			let unbuiltXCFramework = UnbuiltDynamicXCFramework(frameworks: frameworks, skipExistingArtifacts: skipExistingArtifacts)
			try unbuiltXCFramework.buildXCFramework(at: buildPaths.resultXCFrameworkDynamic)
		}
		
		/* Create the final XCFramework package (XCFramework archives and Package.swift file) */
		do {
			let unbuiltXCFrameworkPackage = UnbuiltXCFrameworkPackage(buildPaths: buildPaths, skipExistingArtifacts: skipExistingArtifacts)
			try unbuiltXCFrameworkPackage.buildXCFrameworkPackage(openldapVersion: openldapVersion)
		}
	}
	
	private struct PlatformAndSdk : Hashable, CustomStringConvertible {
		
		var platform: String
		var sdk: String
		
		var pathComponent: FilePath.Component {
			/* The forced-unwrap is **not** fully safe! But the same assumption is
			 * made in Target from which the PlatformAndSdk objects are built. */
			return FilePath.Component(description)!
		}
		
		var description: String {
			/* We assume the sdk and platform are valid (do not contain dashes). */
			return [sdk, platform].joined(separator: "-")
		}
		
	}
	
	private static var defaultFilesFolderURL: URL {
		var base = Bundle.main.bundleURL.deletingLastPathComponent()
		if base.pathComponents.contains("DerivedData") {
			base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		} else if base.pathComponents.contains(".build") {
			base = base.deletingLastPathComponent().deletingLastPathComponent()
		}
		return base.appendingPathComponent("Files")
	}
	
}
