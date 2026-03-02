// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/crypto;
import ballerina/data.jsondata;
import ballerina/data.yaml;
import ballerina/file;
import ballerinax/github;
import ballerina/http;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/os;

// Logging utility function for structured output
isolated function print(string message, string level, int indentation) {
    string spaces = string:'join("", from int i in 0 ..< indentation select "\t");
    io:println(string `${spaces}[${level}] ${message}`);
}

// Versioning strategy types
const RELEASE_TAG_BASED = "release-tag-based";
const FILE_BASED = "file-based";

// Resolution record type
type Resolution record {|
    string parentDirectory;
    string strategy;
|};

// Spec metadata entry record type
type SpecEntry record {|
    string identifier;
    string lastVersion;
    string specPath;
    string documentationUrl;
    string? branch = ();
    string? connectorRepo = ();
    string? lastContentHash = ();
    Resolution resolution;
|};

// Root config record type
type SpecMetadataConfig record {|
    SpecEntry[] specMetadata;
|};

// Update result record
type UpdateResult record {|
    string identifier;
    SpecEntry spec;
    string oldVersion;
    string newVersion;
    string apiVersion;
    string downloadUrl;
    string localPath;
    boolean contentChanged;
    string updateType;
    string folderPath;
|};

// File info record for file-based strategy
type FileInfo record {|
    string path;
    string version;
    int versionNum;
    int rolloutNum;
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Check for content updates
function hasContentChanged(string? oldHash, string newHash) returns boolean {
    if oldHash is () || oldHash == "" {
        return true;
    }
    return oldHash != newHash;
}

// Calculate SHA-256 hash of content
function calculateHash(string content) returns string {
    byte[] contentBytes = content.toBytes();
    byte[] hashBytes = crypto:hashSha256(contentBytes);
    return hashBytes.toBase16();
}

// Parse GitHub URL to extract owner, repo, branch, and path
function parseGitHubUrl(string url) returns [string, string, string, string]|error {
    // Format: https://github.com/owner/repo/tree/branch/path
    // or: https://github.com/owner/repo (root of default branch)

    string cleanUrl = url;
    if cleanUrl.startsWith("https://github.com/") {
        cleanUrl = cleanUrl.substring(19);
    } else {
        return error("Invalid GitHub URL format");
    }

    string[] parts = regexp:split(re `/`, cleanUrl);
    if parts.length() < 2 {
        return error("Invalid GitHub URL: missing owner/repo");
    }

    string owner = parts[0];
    string repo = parts[1];
    string branch = "main";
    string path = "";

    if parts.length() > 3 && parts[2] == "tree" {
        branch = parts[3];
        if parts.length() > 4 {
            path = string:'join("/", ...parts.slice(4));
        }
    }

    return [owner, repo, branch, path];
}

// Remove quotes from string
function removeQuotes(string s) returns string {
    return re `"|'`.replace(s, "");
}

// Regex-based version extraction as fallback
function extractApiVersionWithRegex(string content) returns string|error {
    print("Using regex-based version extraction", "Info", 2);

    string[] lines = regexp:split(re `\n`, content);
    boolean inInfoSection = false;

    foreach string line in lines {
        string trimmedLine = line.trim();

        if trimmedLine.startsWith("\"version\":") || trimmedLine.startsWith("'version':") {
            string[] parts = regexp:split(re `:`, trimmedLine);
            if parts.length() >= 2 {
                string versionValue = parts[1].trim();
                versionValue = removeQuotes(versionValue);
                versionValue = regexp:replace(re `,`, versionValue, "").trim();
                if versionValue.length() > 0 {
                    print(string `Extracted version via regex (JSON): ${versionValue}`, "Info", 2);
                    return versionValue;
                }
            }
        }

        if trimmedLine == "info:" {
            inInfoSection = true;
            continue;
        }

        if inInfoSection {
            if !line.startsWith(" ") && !line.startsWith("\t") && trimmedLine != "" && !trimmedLine.startsWith("#") {
                break;
            }

            if trimmedLine.startsWith("version:") {
                string[] parts = regexp:split(re `:`, trimmedLine);
                if parts.length() >= 2 {
                    string versionValue = parts[1].trim();
                    versionValue = removeQuotes(versionValue);
                    print(string `Extracted version via regex (YAML): ${versionValue}`, "Info", 2);
                    return versionValue;
                }
            }
        }
    }

    return error("Could not extract API version from spec using regex");
}

// Extract version from OpenAPI spec using proper YAML/JSON parsing with regex fallback
function extractApiVersion(string content) returns string|error {
    string trimmedContent = content.trim();
    boolean isJson = trimmedContent.startsWith("{") || trimmedContent.startsWith("[");

    json parsedData = {};

    if isJson {
        json|error jsonResult = jsondata:parseString(content);
        if jsonResult is error {
            print(string `JSON parsing failed: ${jsonResult.message()}, falling back to regex`, "Warn", 2);
            return extractApiVersionWithRegex(content);
        }
        parsedData = jsonResult;
    } else {
        json|error yamlResult = yaml:parseString(content);
        if yamlResult is error {
            print(string `YAML parsing failed: ${yamlResult.message()}, falling back to regex`, "Warn", 2);
            return extractApiVersionWithRegex(content);
        }
        parsedData = yamlResult;
    }

    if parsedData is map<json> {
        json? infoField = parsedData["info"];
        if infoField is () {
            print("'info' field not found in parsed spec, falling back to regex", "Warn", 2);
            return extractApiVersionWithRegex(content);
        }

        if infoField is map<json> {
            json? versionField = infoField["version"];
            if versionField is () {
                print("'version' field not found under 'info', falling back to regex", "Warn", 2);
                return extractApiVersionWithRegex(content);
            }

            if versionField is string {
                print(string `Extracted version via YAML/JSON parsing: ${versionField}`, "Info", 2);
                return versionField;
            } else {
                print("'version' field is not a string, falling back to regex", "Warn", 2);
                return extractApiVersionWithRegex(content);
            }
        } else {
            print("'info' field is not a map, falling back to regex", "Warn", 2);
            return extractApiVersionWithRegex(content);
        }
    } else {
        print("Parsed data is not a map, falling back to regex", "Warn", 2);
        return extractApiVersionWithRegex(content);
    }
}

// Helper: extract text content from HTTP response
isolated function getTextFromResponse(http:Response response) returns string|error {
    string|byte[]|error content = response.getTextPayload();
    if content is error {
        return error("Failed to get content from response");
    }
    if content is string {
        return content;
    }
    return check string:fromBytes(content);
}

// Detect file extension from content format
function getFileExtension(string content) returns string {
    string trimmedContent = content.trim();
    boolean isJson = trimmedContent.startsWith("{") || trimmedContent.startsWith("[");
    return isJson ? "json" : "yaml";
}

// Check if a spec file already exists in the directory (either .json or .yaml)
function specFileExists(string dirPath) returns boolean|error {
    if !check file:test(dirPath, file:EXISTS) {
        return false;
    }

    string jsonPath = dirPath + "/openapi.json";
    string yamlPath = dirPath + "/openapi.yaml";

    boolean jsonExists = check file:test(jsonPath, file:EXISTS);
    boolean yamlExists = check file:test(yamlPath, file:EXISTS);

    return jsonExists || yamlExists;
}

// Save spec to file - preserves original format (JSON or YAML)
function saveSpec(string content, string localPath) returns error? {
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }

    check io:fileWriteString(localPath, content);
    print(string `Saved to ${localPath}`, "Info", 1);
    return;
}

// Download raw file from GitHub
function downloadRawFile(string owner, string repo, string branch, string filePath) returns string|error {
    string baseUrl = "https://raw.githubusercontent.com";
    string path = string `/${owner}/${repo}/${branch}/${filePath}`;
    print(string `Downloading from raw GitHub URL: ${baseUrl}${path}`, "Info", 1);

    http:Client httpClient = check new (baseUrl);
    http:Response response = check httpClient->get(path);

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${baseUrl}${path}`);
    }

    return check getTextFromResponse(response);
}

// List GitHub directory contents recursively using GitHub API
function listGitHubDirectoryRecursive(string owner, string repo, string branch, string path, string token) returns string[]|error {
    print(string `Listing directory: ${path}`, "Info", 2);

    string baseUrl = "https://api.github.com";
    string apiPath = string `/repos/${owner}/${repo}/contents/${path}?ref=${branch}`;

    http:Client httpClient = check new (baseUrl);
    map<string> headers = {
        "Authorization": string `Bearer ${token}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    };

    http:Response response = check httpClient->get(apiPath, headers);

    if response.statusCode != 200 {
        return error(string `Failed to list directory: HTTP ${response.statusCode}`);
    }

    json|error content = response.getJsonPayload();
    if content is error {
        return error("Failed to parse directory listing");
    }

    string[] allFiles = [];

    if content is json[] {
        foreach json item in content {
            if item is map<json> {
                json? itemType = item["type"];
                json? itemPath = item["path"];

                if itemType is string && itemPath is string {
                    if itemType == "file" {
                        allFiles.push(itemPath);
                    } else if itemType == "dir" {
                        // Recurse into subdirectory
                        string[]|error subFiles = listGitHubDirectoryRecursive(owner, repo, branch, itemPath, token);
                        if subFiles is string[] {
                            foreach string subFile in subFiles {
                                allFiles.push(subFile);
                            }
                        }
                    }
                }
            }
        }
        return allFiles;
    }

    return error("Unexpected response format from GitHub API");
}

// Extract version number from path for comparison (handles rollout numbers and version numbers)
// Returns [rolloutNum, majorVersion, minorVersion] for proper comparison
function extractVersionNumbers(string filePath) returns [int, int, int] {
    int rolloutNum = 0;
    int majorVersion = 0;
    int minorVersion = 0;

    // Extract rollout number (e.g., "Rollouts/148901/v4" -> 148901)
    regexp:Groups? rolloutGroups = re `Rollouts/([0-9]+)`.findGroups(filePath);
    if rolloutGroups is regexp:Groups && rolloutGroups.length() > 1 {
        regexp:Span? span = rolloutGroups[1];
        if span is regexp:Span {
            int|error num = int:fromString(span.substring());
            if num is int {
                rolloutNum = num;
            }
        }
    }

    // Extract version number from path (e.g., "/v4/" -> 4)
    regexp:Groups? versionGroups = re `/v([0-9]+)/`.findGroups(filePath);
    if versionGroups is regexp:Groups && versionGroups.length() > 1 {
        regexp:Span? span = versionGroups[1];
        if span is regexp:Span {
            int|error num = int:fromString(span.substring());
            if num is int {
                majorVersion = num;
            }
        }
    }

    // Extract version from filename (e.g., "swagger-v2.1.json" -> major=2, minor=1)
    // or "swagger-v2.json" -> major=2, minor=0
    regexp:Groups? fileVersionGroups = re `-v([0-9]+)\.([0-9]+)\.`.findGroups(filePath);
    if fileVersionGroups is regexp:Groups && fileVersionGroups.length() > 2 {
        regexp:Span? majorSpan = fileVersionGroups[1];
        regexp:Span? minorSpan = fileVersionGroups[2];
        if majorSpan is regexp:Span && minorSpan is regexp:Span {
            int|error majorNum = int:fromString(majorSpan.substring());
            int|error minorNum = int:fromString(minorSpan.substring());
            if majorNum is int && minorNum is int {
                majorVersion = majorNum;
                minorVersion = minorNum;
            }
        }
    } else {
        // Try pattern like "-v2.json" (no minor version)
        regexp:Groups? fileVersionSimple = re `-v([0-9]+)\.json`.findGroups(filePath);
        if fileVersionSimple is regexp:Groups && fileVersionSimple.length() > 1 {
            regexp:Span? majorSpan = fileVersionSimple[1];
            if majorSpan is regexp:Span {
                int|error majorNum = int:fromString(majorSpan.substring());
                if majorNum is int {
                    majorVersion = majorNum;
                    minorVersion = 0;
                }
            }
        }
    }

    return [rolloutNum, majorVersion, minorVersion];
}

// Find the best matching file (highest rollout + highest version)
function findBestMatchingFile(string[] files, string specPathRegex) returns string|error {
    print(string `Finding best match for regex: ${specPathRegex}`, "Info", 2);
    print(string `Total files to search: ${files.length()}`, "Info", 2);

    string? bestFile = ();
    int bestRollout = -1;
    int bestMajorVersion = -1;
    int bestMinorVersion = -1;

    // Compile regex pattern
    regexp:RegExp pattern = check regexp:fromString(specPathRegex);

    foreach string filePath in files {
        // Get just the filename
        string[] pathParts = regexp:split(re `/`, filePath);
        string fileName = pathParts[pathParts.length() - 1];

        // Skip "Collection" files - these are Postman collections, not OpenAPI specs
        if fileName.includes("Collection") {
            continue;
        }

        // Check if filename matches pattern
        boolean matches = pattern.isFullMatch(fileName);

        if matches {
            [int, int, int] [rollout, majorVer, minorVer] = extractVersionNumbers(filePath);
            print(string `Match: ${filePath} (rollout: ${rollout}, version: ${majorVer}.${minorVer})`, "Info", 3);

            // Compare: first by rollout, then by major version, then by minor version
            boolean isBetter = false;
            if rollout > bestRollout {
                isBetter = true;
            } else if rollout == bestRollout {
                if majorVer > bestMajorVersion {
                    isBetter = true;
                } else if majorVer == bestMajorVersion && minorVer > bestMinorVersion {
                    isBetter = true;
                }
            }

            if isBetter {
                bestRollout = rollout;
                bestMajorVersion = majorVer;
                bestMinorVersion = minorVer;
                bestFile = filePath;
            }
        }
    }

    if bestFile is string {
        print(string `Best match: ${bestFile}`, "Info", 2);
        return bestFile;
    }

    return error("No matching files found");
}

// Process repository with release-tag based strategy
function processReleaseTagRepo(github:Client githubClient, SpecEntry spec, string token) returns UpdateResult|error? {
    print(string `Checking: ${spec.identifier} [Release-Tag Strategy]`, "Info", 0);

    // Parse the parent directory URL
    [string, string, string, string]|error urlParts = parseGitHubUrl(spec.resolution.parentDirectory);
    if urlParts is error {
        print(string `Failed to parse URL: ${urlParts.message()}`, "Error", 1);
        return urlParts;
    }

    var [owner, repo, _, basePath] = urlParts;

    // Get latest release
    github:Release|error latestRelease = githubClient->/repos/[owner]/[repo]/releases/latest();

    if latestRelease is error {
        string errorMsg = latestRelease.message();
        if errorMsg.includes("404") {
            print(string `No releases found for ${owner}/${repo}`, "Error", 1);
        } else if errorMsg.includes("401") || errorMsg.includes("403") {
            print("Authentication failed", "Error", 1);
        } else {
            print(string `Error: ${errorMsg}`, "Error", 1);
        }
        return latestRelease;
    }

    string tagName = latestRelease.tag_name;
    string? publishedAt = latestRelease.published_at;

    if latestRelease.prerelease || latestRelease.draft {
        print(string `Skipping pre-release: ${tagName}`, "Info", 1);
        return ();
    }

    print(string `Latest release tag: ${tagName}`, "Info", 1);
    if publishedAt is string {
        print(string `Published: ${publishedAt}`, "Info", 1);
    }

    // For release-tag strategy, list files in the directory and find the best match using specPath regex
    print(string `Listing files in ${basePath} to find spec matching pattern: ${spec.specPath}`, "Info", 1);

    // List files using release tag as branch
    string[]|error allFiles = listGitHubDirectoryRecursive(owner, repo, tagName, basePath, token);
    if allFiles is error {
        print(string `Failed to list files: ${allFiles.message()}`, "Error", 1);
        return allFiles;
    }

    // Find best matching file using the specPath regex
    string|error bestFileResult = findBestMatchingFile(allFiles, spec.specPath);
    if bestFileResult is error {
        print(string `No matching spec file found: ${bestFileResult.message()}`, "Error", 1);
        return bestFileResult;
    }

    string specFilePath = bestFileResult;
    print(string `Selected spec file: ${specFilePath}`, "Info", 1);

    // Download the spec
    string|error specContent = downloadRawFile(owner, repo, tagName, specFilePath);
    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return specContent;
    }

    // Check for changes
    boolean versionChanged = hasVersionChanged(spec.lastVersion, tagName);
    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(spec.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    if !versionChanged && !contentChanged {
        print(string `No updates (version: ${spec.lastVersion}, content unchanged)`, "Info", 1);
        return ();
    }

    string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
    print(string `UPDATE DETECTED! (Type: ${updateType})`, "Info", 1);

    // Extract API version
    string|error apiVersionResult = extractApiVersion(specContent);
    string apiVersion = apiVersionResult is string ? apiVersionResult :
        (tagName.startsWith("v") ? tagName.substring(1) : tagName);

    print(string `API Version: ${apiVersion}`, "Info", 1);

    string versionDir = "../openapi/" + spec.identifier + "/" + apiVersion;

    // Check if spec file already exists
    boolean fileExists = check specFileExists(versionDir);
    if fileExists {
        print(string `Spec file already exists for version ${apiVersion}, skipping save`, "Info", 1);
        return ();
    }

    string fileExtension = getFileExtension(specContent);
    string localPath = versionDir + "/openapi." + fileExtension;

    error? saveResult = saveSpec(specContent, localPath);
    if saveResult is error {
        print("Save failed: " + saveResult.message(), "Error", 1);
        return saveResult;
    }

    string oldVersion = spec.lastVersion;
    spec.lastVersion = tagName;
    spec.lastContentHash = contentHash;

    string folderPath = "openapi/" + spec.identifier + "/" + apiVersion;

    return {
        identifier: spec.identifier,
        spec: spec,
        oldVersion: oldVersion,
        newVersion: tagName,
        apiVersion: apiVersion,
        downloadUrl: string `https://github.com/${owner}/${repo}/releases/tag/${tagName}`,
        localPath: localPath,
        contentChanged: contentChanged,
        updateType: updateType,
        folderPath: folderPath
    };
}

// Process repository with file-based strategy (handles both simple file-based and rollout-based)
function processFileBasedRepo(SpecEntry spec, string token) returns UpdateResult|error? {
    print(string `Checking: ${spec.identifier} [File-Based Strategy]`, "Info", 0);

    // Parse the parent directory URL
    [string, string, string, string]|error urlParts = parseGitHubUrl(spec.resolution.parentDirectory);
    if urlParts is error {
        print(string `Failed to parse URL: ${urlParts.message()}`, "Error", 1);
        return urlParts;
    }

    var [owner, repo, branch, basePath] = urlParts;

    // Use branch from spec if provided, otherwise use parsed branch
    string actualBranch = spec.branch is string ? <string>spec.branch : branch;

    print(string `Repository: ${owner}/${repo}`, "Info", 1);
    print(string `Branch: ${actualBranch}`, "Info", 1);
    print(string `Base path: ${basePath}`, "Info", 1);
    print(string `Spec pattern: ${spec.specPath}`, "Info", 1);

    // Step 1: List all files in the directory recursively
    print("Fetching file list from GitHub...", "Info", 1);
    string[]|error allFiles = listGitHubDirectoryRecursive(owner, repo, actualBranch, basePath, token);

    if allFiles is error {
        print(string `Failed to list files: ${allFiles.message()}`, "Error", 1);
        return allFiles;
    }

    print(string `Found ${allFiles.length()} files`, "Info", 1);

    // Step 2: Find the best matching file (highest rollout + version)
    string|error bestFile = findBestMatchingFile(allFiles, spec.specPath);

    if bestFile is error {
        print(string `No matching files found: ${bestFile.message()}`, "Error", 1);
        return bestFile;
    }

    print(string `Selected file: ${bestFile}`, "Info", 1);

    // Step 3: Download the spec file
    string|error specContent = downloadRawFile(owner, repo, actualBranch, bestFile);

    if specContent is error {
        print("Download failed: " + specContent.message(), "Error", 1);
        return specContent;
    }

    // Step 4: Calculate content hash and extract version
    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(spec.lastContentHash, contentHash);

    print(string `Content Hash: ${contentHash.substring(0, 16)}...`, "Info", 1);

    // Extract API version from spec content
    string|error apiVersionResult = extractApiVersion(specContent);

    if apiVersionResult is error {
        print("Could not extract API version from spec content", "Error", 1);
        return apiVersionResult;
    }

    string apiVersion = apiVersionResult;
    print(string `API Version: ${apiVersion}`, "Info", 1);

    // Extract rollout number from path for version tracking
    [int, int, int] [rolloutNum, _, _] = extractVersionNumbers(bestFile);
    string newVersion = rolloutNum > 0 ? rolloutNum.toString() : apiVersion;

    boolean versionChanged = hasVersionChanged(spec.lastVersion, newVersion);

    if !versionChanged && !contentChanged {
        print(string `No updates (version: ${apiVersion}, content unchanged)`, "Info", 1);
        return ();
    }

    string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
    print(string `UPDATE DETECTED! (${spec.lastVersion} -> ${newVersion}, Type: ${updateType})`, "Info", 1);

    // Structure: openapi/{identifier}/{apiVersion}/
    string versionDir = "../openapi/" + spec.identifier + "/" + apiVersion;

    // For file-based, we always update to latest (remove old if exists)
    string fileExtension = getFileExtension(specContent);
    string localPath = versionDir + "/openapi." + fileExtension;

    // Remove existing spec files if any (to replace with latest rollout)
    if check file:test(versionDir, file:EXISTS) {
        string jsonPath = versionDir + "/openapi.json";
        string yamlPath = versionDir + "/openapi.yaml";

        if check file:test(jsonPath, file:EXISTS) {
            check file:remove(jsonPath);
            print("Removed existing openapi.json", "Info", 2);
        }
        if check file:test(yamlPath, file:EXISTS) {
            check file:remove(yamlPath);
            print("Removed existing openapi.yaml", "Info", 2);
        }
    }

    error? saveResult = saveSpec(specContent, localPath);
    if saveResult is error {
        print("Save failed: " + saveResult.message(), "Error", 1);
        return saveResult;
    }

    string oldVersion = spec.lastVersion;
    spec.lastVersion = newVersion;
    spec.lastContentHash = contentHash;

    string folderPath = "openapi/" + spec.identifier + "/" + apiVersion;

    return {
        identifier: spec.identifier,
        spec: spec,
        oldVersion: oldVersion,
        newVersion: newVersion,
        apiVersion: apiVersion,
        downloadUrl: string `https://github.com/${owner}/${repo}/blob/${actualBranch}/${bestFile}`,
        localPath: localPath,
        contentChanged: contentChanged,
        updateType: updateType,
        folderPath: folderPath
    };
}

// Write repos.json with the new structure
function writeReposJson(SpecMetadataConfig config) returns error? {
    json configJson = config.toJson();
    string formattedJson = configJson.toJsonString();
    check io:fileWriteString("../repos.json", formattedJson);
    return;
}

// Main monitoring function
public function main() returns error? {
    print("=== Dependabot OpenAPI Monitor ===", "Info", 0);
    print("Starting OpenAPI specification monitoring...", "Info", 0);

    // Get GitHub token
    string? ghToken = os:getEnv("GH_TOKEN");
    string? ballerinaToken = os:getEnv("BALLERINA_BOT_TOKEN");
    string? githubToken = os:getEnv("GITHUB_TOKEN");

    string token = "";
    if ghToken is string && ghToken.length() > 0 {
        token = ghToken;
    } else if ballerinaToken is string && ballerinaToken.length() > 0 {
        token = ballerinaToken;
    } else if githubToken is string && githubToken.length() > 0 {
        token = githubToken;
    }

    if token.length() == 0 {
        print("GitHub token not found. Please set one of: GH_TOKEN, BALLERINA_BOT_TOKEN, or GITHUB_TOKEN", "Error", 0);
        return;
    }

    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token: token
        }
    });

    // Load configuration from repos.json
    json reposJson = check io:fileReadJson("../repos.json");
    SpecMetadataConfig config = check reposJson.cloneWithType();

    print(string `Found ${config.specMetadata.length()} specifications to monitor.`, "Info", 0);
    io:println("");

    // Track updates
    UpdateResult[] updates = [];

    // Check each specification based on strategy
    foreach int i in 0 ..< config.specMetadata.length() {
        SpecEntry spec = config.specMetadata[i];
        UpdateResult|error? result = ();

        if spec.resolution.strategy == RELEASE_TAG_BASED {
            result = processReleaseTagRepo(githubClient, spec, token);
        } else if spec.resolution.strategy == FILE_BASED {
            result = processFileBasedRepo(spec, token);
        } else {
            print(string `Unknown strategy: ${spec.resolution.strategy}`, "Warn", 0);
        }

        if result is UpdateResult {
            updates.push(result);
            // Update the spec in config array
            config.specMetadata[i] = result.spec;
        }

        io:println("");
    }

    // Report updates
    if updates.length() > 0 {
        io:println("");
        print(string `Found ${updates.length()} updates:`, "Info", 0);
        io:println("");

        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string summary = string `${update.identifier}:${update.apiVersion}`;
            print(string `${update.identifier}: ${update.oldVersion} -> ${update.newVersion} (${update.updateType} update)`, "Info", 1);
            updateSummary.push(summary);
        }

        // Update repos.json
        error? writeResult = writeReposJson(config);
        if writeResult is error {
            print("Failed to write repos.json: " + writeResult.message(), "Error", 0);
            return writeResult;
        }
        io:println("");
        print("Updated repos.json with new versions and content hashes", "Info", 0);

        // Write update summary
        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("../UPDATE_SUMMARY.txt", summaryContent);

        io:println("");
        print("Changes detected and saved. The workflow will create a PR automatically.", "Info", 0);

    } else {
        print("All specifications are up-to-date!", "Info", 0);
    }
}
