#import "CodePush.h"
#import "SSZipArchive.h"
#import "DiffMatchPatch.h"

@implementation CodePushPackage

#pragma mark - Private constants

static NSString *const DiffManifestFileName = @"hotcodepush.json";
static NSString *const DownloadFileName = @"download.zip";
static NSString *const RelativeBundlePathKey = @"bundlePath";
static NSString *const StatusFile = @"codepush.json";
static NSString *const UpdateBundleFileName = @"app.jsbundle";
static NSString *const UpdateMetadataFileName = @"app.json";
static NSString *const UnzippedFolderName = @"unzipped";

#pragma mark - Public methods

+ (void)clearUpdates
{
    [[NSFileManager defaultManager] removeItemAtPath:[self getCodePushPath] error:nil];
}

+ (void)downloadAndReplaceCurrentBundle:(NSString *)remoteBundleUrl
{
    NSURL *urlRequest = [NSURL URLWithString:remoteBundleUrl];
    NSError *error = nil;
    NSString *downloadedBundle = [NSString stringWithContentsOfURL:urlRequest
                                                          encoding:NSUTF8StringEncoding
                                                             error:&error];
    
    if (error) {
        CPLog(@"Error downloading from URL %@", remoteBundleUrl);
    } else {
        NSString *currentPackageBundlePath = [self getCurrentPackageBundlePath:&error];
        [downloadedBundle writeToFile:currentPackageBundlePath
                           atomically:YES
                             encoding:NSUTF8StringEncoding
                                error:&error];
    }
}

+ (void)downloadPackage:(NSDictionary *)updatePackage
 expectedBundleFileName:(NSString *)expectedBundleFileName
         operationQueue:(dispatch_queue_t)operationQueue
       progressCallback:(void (^)(long long, long long))progressCallback
           doneCallback:(void (^)())doneCallback
           failCallback:(void (^)(NSError *err))failCallback
{
    NSString *newUpdateHash = updatePackage[@"packageHash"];
    NSString *newUpdateFolderPath = [self getPackageFolderPath:newUpdateHash];
    NSString *newUpdateMetadataPath = [newUpdateFolderPath stringByAppendingPathComponent:UpdateMetadataFileName];
    NSError *error;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:newUpdateFolderPath]) {
        // This removes any stale data in newUpdateFolderPath that could have been left
        // uncleared due to a crash or error during the download or install process.
        [[NSFileManager defaultManager] removeItemAtPath:newUpdateFolderPath
                                                   error:&error];
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:[self getCodePushPath]]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[self getCodePushPath]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        
        // Ensure that none of the CodePush updates we store on disk are
        // ever included in the end users iTunes and/or iCloud backups
        NSURL *codePushURL = [NSURL fileURLWithPath:[self getCodePushPath]];
        [codePushURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    
    if (error) {
        return failCallback(error);
    }
    
    NSString *downloadFilePath = [self getDownloadFilePath];
    NSString *bundleFilePath = [newUpdateFolderPath stringByAppendingPathComponent:UpdateBundleFileName];
    
    CodePushDownloadHandler *downloadHandler = [[CodePushDownloadHandler alloc]
                                                init:downloadFilePath
                                                operationQueue:operationQueue
                                                progressCallback:progressCallback
                                                doneCallback:^(BOOL isZip) {
                                                    NSError *error = nil;
                                                    NSString * unzippedFolderPath = [CodePushPackage getUnzippedFolderPath];
                                                    NSMutableDictionary * mutableUpdatePackage = [updatePackage mutableCopy];
                                                    if (isZip) {
                                                        if ([[NSFileManager defaultManager] fileExistsAtPath:unzippedFolderPath]) {
                                                            // This removes any unzipped download data that could have been left
                                                            // uncleared due to a crash or error during the download process.
                                                            [[NSFileManager defaultManager] removeItemAtPath:unzippedFolderPath
                                                                                                       error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                        }
                                                        
                                                        NSError *nonFailingError = nil;
                                                        [SSZipArchive unzipFileAtPath:downloadFilePath
                                                                        toDestination:unzippedFolderPath];
                                                        [[NSFileManager defaultManager] removeItemAtPath:downloadFilePath
                                                                                                   error:&nonFailingError];
                                                        if (nonFailingError) {
                                                            CPLog(@"Error deleting downloaded file: %@", nonFailingError);
                                                            nonFailingError = nil;
                                                        }
                                                        
                                                        NSString *diffManifestFilePath = [unzippedFolderPath stringByAppendingPathComponent:DiffManifestFileName];
                                                        BOOL isDiffUpdate = [[NSFileManager defaultManager] fileExistsAtPath:diffManifestFilePath];
                                                        
                                                        if (isDiffUpdate) {
                                                            // Copy the current package to the new package.
                                                            NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                            
                                                            if (currentPackageFolderPath == nil) {
                                                                // Currently running the binary version, copy files from the bundled resources
                                                                NSString *newUpdateCodePushPath = [newUpdateFolderPath stringByAppendingPathComponent:[CodePushUpdateUtils manifestFolderPrefix]];
                                                                //NSString *newUpdateCodePushPath = newUpdateFolderPath;
                                                                [[NSFileManager defaultManager] createDirectoryAtPath:newUpdateCodePushPath
                                                                                          withIntermediateDirectories:YES
                                                                                                           attributes:nil
                                                                                                                error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                                
                                                                [[NSFileManager defaultManager] copyItemAtPath:[CodePush bundleAssetsPath]
                                                                                                        toPath:[newUpdateCodePushPath stringByAppendingPathComponent:[CodePushUpdateUtils assetsFolderName]]
                                                                                                         error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                                
                                                                [[NSFileManager defaultManager] copyItemAtPath:[[CodePush binaryBundleURL] path]
                                                                                                        toPath:[newUpdateCodePushPath stringByAppendingPathComponent:[[CodePush binaryBundleURL] lastPathComponent]]
                                                                                                         error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                                
                                                            } else {
                                                                [[NSFileManager defaultManager] copyItemAtPath:currentPackageFolderPath
                                                                                                        toPath:newUpdateFolderPath
                                                                                                         error:&error];
                                                                if (error) {
                                                                    failCallback(error);
                                                                    return;
                                                                }
                                                            }
                                                            
                                                            // Delete files mentioned in the manifest.
                                                            NSString *manifestContent = [NSString stringWithContentsOfFile:diffManifestFilePath
                                                                                                                  encoding:NSUTF8StringEncoding
                                                                                                                     error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                            
                                                            NSData *data = [manifestContent dataUsingEncoding:NSUTF8StringEncoding];
                                                            NSDictionary *manifestJSON = [NSJSONSerialization JSONObjectWithData:data
                                                                                                                         options:kNilOptions
                                                                                                                           error:&error];
                                                            NSArray *deletedFiles = manifestJSON[@"deletedFiles"];
                                                            if ([deletedFiles isKindOfClass:[NSArray class]]){
                                                                for (NSString *deletedFileName in deletedFiles) {
                                                                    NSString *absoluteDeletedFilePath = [newUpdateFolderPath stringByAppendingPathComponent:deletedFileName];
                                                                    if ([[NSFileManager defaultManager] fileExistsAtPath:absoluteDeletedFilePath]) {
                                                                        [[NSFileManager defaultManager] removeItemAtPath:absoluteDeletedFilePath
                                                                                                                   error:&error];
                                                                        if (error) {
                                                                            failCallback(error);
                                                                            return;
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                            
                                                            NSArray *patchFiles = manifestJSON[@"patchedFiles"];
                                                            if ([patchFiles isKindOfClass:[NSArray class]]){
                                                                for (NSString *patchFileName in patchFiles) {
                                                                    
                                                                    NSString *originalFileName = [patchFileName stringByReplacingOccurrencesOfString:@".patch" withString:@""];
                                                                    NSString *absoluteOrignalFilePath = [newUpdateFolderPath stringByAppendingPathComponent:originalFileName];
                                                                    
                                                                    NSString *absolutePatchFilePath = [unzippedFolderPath stringByAppendingPathComponent:patchFileName];
                                                                    
                                                                    if ([[NSFileManager defaultManager] fileExistsAtPath:absoluteOrignalFilePath]
                                                                        && [[NSFileManager defaultManager] fileExistsAtPath:absolutePatchFilePath]) {
                                                                        
                                                                        NSString *originalText = [NSString stringWithContentsOfFile:absoluteOrignalFilePath encoding:NSUTF8StringEncoding error:&error];
                                                                        if (error) {
                                                                            failCallback(error);
                                                                            return;
                                                                        }
                                                                        
                                                                        NSString *patchText = [NSString stringWithContentsOfFile:absolutePatchFilePath encoding:NSUTF8StringEncoding error:&error];
                                                                        if (error) {
                                                                            failCallback(error);
                                                                            return;
                                                                        }
                                                                        
                                                                        NSArray *patches = patch_parsePatchesFromText(patchText, &error);
                                                                        if (error) {
                                                                            failCallback(error);
                                                                            return;
                                                                        }
                                                                        
                                                                        NSString *resultText = patch_applyPatchesToText(patches, originalText, NULL);
                                                                        
                                                                        [resultText writeToFile:absoluteOrignalFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
                                                                        if (error) {
                                                                            failCallback(error);
                                                                            return;
                                                                        }
                                                                        [[NSFileManager defaultManager] removeItemAtPath:absolutePatchFilePath
                                                                                                                   error:&error];
                                                                        if (error) {
                                                                            failCallback(error);
                                                                            return;
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                            
                                                            [[NSFileManager defaultManager] removeItemAtPath:diffManifestFilePath
                                                                                                       error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                        }
                                                        
                                                        [CodePushUpdateUtils copyEntriesInFolder:unzippedFolderPath
                                                                                      destFolder:newUpdateFolderPath
                                                                                           error:&error];
                                                        if (error) {
                                                            failCallback(error);
                                                            return;
                                                        }
                                                        
                                                        [[NSFileManager defaultManager] removeItemAtPath:unzippedFolderPath
                                                                                                   error:&nonFailingError];
                                                        if (nonFailingError) {
                                                            CPLog(@"Error deleting downloaded file: %@", nonFailingError);
                                                            nonFailingError = nil;
                                                        }
                                                        
                                                        NSString *relativeBundlePath = [CodePushUpdateUtils findMainBundleInFolder:newUpdateFolderPath
                                                                                                                  expectedFileName:expectedBundleFileName
                                                                                                                             error:&error];
                                                        
                                                        if (error) {
                                                            failCallback(error);
                                                            return;
                                                        }
                                                        
                                                        if (relativeBundlePath) {
                                                            [mutableUpdatePackage setValue:relativeBundlePath forKey:RelativeBundlePathKey];
                                                        } else {
                                                            NSString *errorMessage = [NSString stringWithFormat:@"Update is invalid - A JS bundle file named \"%@\" could not be found within the downloaded contents. Please ensure that your app is syncing with the correct deployment and that you are releasing your CodePush updates using the exact same JS bundle file name that was shipped with your app's binary.", expectedBundleFileName];
                                                            
                                                            error = [CodePushErrorUtils errorWithMessage:errorMessage];
                                                            
                                                            failCallback(error);
                                                            return;
                                                        }
                                                        
                                                        if ([[NSFileManager defaultManager] fileExistsAtPath:newUpdateMetadataPath]) {
                                                            [[NSFileManager defaultManager] removeItemAtPath:newUpdateMetadataPath
                                                                                                       error:&error];
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                        }
                                                        
                                                        if (isDiffUpdate && ![CodePushUpdateUtils verifyHashForDiffUpdate:newUpdateFolderPath
                                                                                                             expectedHash:newUpdateHash
                                                                                                                    error:&error]) {
                                                            if (error) {
                                                                failCallback(error);
                                                                return;
                                                            }
                                                            
                                                            error = [CodePushErrorUtils errorWithMessage:@"The update contents failed the data integrity check."];
                                                            
                                                            failCallback(error);
                                                            return;
                                                        }
                                                    } else {
                                                        [[NSFileManager defaultManager] createDirectoryAtPath:newUpdateFolderPath
                                                                                  withIntermediateDirectories:YES
                                                                                                   attributes:nil
                                                                                                        error:&error];
                                                        [[NSFileManager defaultManager] moveItemAtPath:downloadFilePath
                                                                                                toPath:bundleFilePath
                                                                                                 error:&error];
                                                        if (error) {
                                                            failCallback(error);
                                                            return;
                                                        }
                                                    }
                                                    
                                                    NSData *updateSerializedData = [NSJSONSerialization dataWithJSONObject:mutableUpdatePackage
                                                                                                                   options:0
                                                                                                                     error:&error];
                                                    NSString *packageJsonString = [[NSString alloc] initWithData:updateSerializedData
                                                                                                        encoding:NSUTF8StringEncoding];
                                                    
                                                    [packageJsonString writeToFile:newUpdateMetadataPath
                                                                        atomically:YES
                                                                          encoding:NSUTF8StringEncoding
                                                                             error:&error];
                                                    if (error) {
                                                        failCallback(error);
                                                    } else {
                                                        doneCallback();
                                                    }
                                                }
                                                
                                                failCallback:failCallback];
    
    [downloadHandler download:updatePackage[@"downloadUrl"]];
}

+ (NSString *)getCodePushPath
{
    NSString* codePushPath = [[CodePush getApplicationSupportDirectory] stringByAppendingPathComponent:@"CodePush"];
    if ([CodePush isUsingTestConfiguration]) {
        codePushPath = [codePushPath stringByAppendingPathComponent:@"TestPackages"];
    }
    
    return codePushPath;
}

+ (NSDictionary *)getCurrentPackage:(NSError **)error
{
    NSString *packageHash = [CodePushPackage getCurrentPackageHash:error];
    if (!packageHash) {
        return nil;
    }
    
    return [CodePushPackage getPackage:packageHash error:error];
}

+ (NSString *)getCurrentPackageBundlePath:(NSError **)error
{
    NSString *packageFolder = [self getCurrentPackageFolderPath:error];
    
    if (!packageFolder) {
        return nil;
    }
    
    NSDictionary *currentPackage = [self getCurrentPackage:error];
    
    if (!currentPackage) {
        return nil;
    }
    
    NSString *relativeBundlePath = [currentPackage objectForKey:RelativeBundlePathKey];
    if (relativeBundlePath) {
        return [packageFolder stringByAppendingPathComponent:relativeBundlePath];
    } else {
        return [packageFolder stringByAppendingPathComponent:UpdateBundleFileName];
    }
}

+ (NSString *)getCurrentPackageHash:(NSError **)error
{
    NSDictionary *info = [self getCurrentPackageInfo:error];
    if (!info) {
        return nil;
    }
    
    return info[@"currentPackage"];
}

+ (NSString *)getCurrentPackageFolderPath:(NSError **)error
{
    NSDictionary *info = [self getCurrentPackageInfo:error];
    
    if (!info) {
        return nil;
    }
    
    NSString *packageHash = info[@"currentPackage"];
    
    if (!packageHash) {
        return nil;
    }
    
    return [self getPackageFolderPath:packageHash];
}

+ (NSMutableDictionary *)getCurrentPackageInfo:(NSError **)error
{
    NSString *statusFilePath = [self getStatusFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:statusFilePath]) {
        return [NSMutableDictionary dictionary];
    }
    
    NSString *content = [NSString stringWithContentsOfFile:statusFilePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:error];
    if (!content) {
        return nil;
    }
    
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:kNilOptions
                                                           error:error];
    if (!json) {
        return nil;
    }
    
    return [json mutableCopy];
}

+ (NSString *)getDownloadFilePath
{
    return [[self getCodePushPath] stringByAppendingPathComponent:DownloadFileName];
}

+ (NSDictionary *)getPackage:(NSString *)packageHash
                       error:(NSError **)error
{
    NSString *updateDirectoryPath = [self getPackageFolderPath:packageHash];
    NSString *updateMetadataFilePath = [updateDirectoryPath stringByAppendingPathComponent:UpdateMetadataFileName];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:updateMetadataFilePath]) {
        return nil;
    }
    
    NSString *updateMetadataString = [NSString stringWithContentsOfFile:updateMetadataFilePath
                                                               encoding:NSUTF8StringEncoding
                                                                  error:error];
    if (!updateMetadataString) {
        return nil;
    }
    
    NSData *updateMetadata = [updateMetadataString dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:updateMetadata
                                           options:kNilOptions
                                             error:error];
}

+ (NSString *)getPackageFolderPath:(NSString *)packageHash
{
    return [[self getCodePushPath] stringByAppendingPathComponent:packageHash];
}

+ (NSDictionary *)getPreviousPackage:(NSError **)error
{
    NSString *packageHash = [self getPreviousPackageHash:error];
    if (!packageHash) {
        return nil;
    }
    
    return [CodePushPackage getPackage:packageHash error:error];
}

+ (NSString *)getPreviousPackageHash:(NSError **)error
{
    NSDictionary *info = [self getCurrentPackageInfo:error];
    if (!info) {
        return nil;
    }
    
    return info[@"previousPackage"];
}

+ (NSString *)getStatusFilePath
{
    return [[self getCodePushPath] stringByAppendingPathComponent:StatusFile];
}

+ (NSString *)getUnzippedFolderPath
{
    return [[self getCodePushPath] stringByAppendingPathComponent:UnzippedFolderName];
}

+ (BOOL)installPackage:(NSDictionary *)updatePackage
   removePendingUpdate:(BOOL)removePendingUpdate
                 error:(NSError **)error
{
    NSString *packageHash = updatePackage[@"packageHash"];
    NSMutableDictionary *info = [self getCurrentPackageInfo:error];
    
    if (!info) {
        return NO;
    }
    
    if (packageHash && [packageHash isEqualToString:info[@"currentPackage"]]) {
        // The current package is already the one being installed, so we should no-op.
        return YES;
    }
    
    if (removePendingUpdate) {
        NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:error];
        if (currentPackageFolderPath) {
            // Error in deleting pending package will not cause the entire operation to fail.
            NSError *deleteError;
            [[NSFileManager defaultManager] removeItemAtPath:currentPackageFolderPath
                                                       error:&deleteError];
            if (deleteError) {
                CPLog(@"Error deleting pending package: %@", deleteError);
            }
        }
    } else {
        NSString *previousPackageHash = [self getPreviousPackageHash:error];
        if (previousPackageHash && ![previousPackageHash isEqualToString:packageHash]) {
            NSString *previousPackageFolderPath = [self getPackageFolderPath:previousPackageHash];
            // Error in deleting old package will not cause the entire operation to fail.
            NSError *deleteError;
            [[NSFileManager defaultManager] removeItemAtPath:previousPackageFolderPath
                                                       error:&deleteError];
            if (deleteError) {
                CPLog(@"Error deleting old package: %@", deleteError);
            }
        }
        [info setValue:info[@"currentPackage"] forKey:@"previousPackage"];
    }
    
    [info setValue:packageHash forKey:@"currentPackage"];
    return [self updateCurrentPackageInfo:info
                                    error:error];
}

+ (void)rollbackPackage
{
    NSError *error;
    NSMutableDictionary *info = [self getCurrentPackageInfo:&error];
    if (!info) {
        CPLog(@"Error getting current package info: %@", error);
        return;
    }
    
    NSString *currentPackageFolderPath = [self getCurrentPackageFolderPath:&error];
    if (!currentPackageFolderPath) {
        CPLog(@"Error getting current package folder path: %@", error);
        return;
    }
    
    NSError *deleteError;
    BOOL result = [[NSFileManager defaultManager] removeItemAtPath:currentPackageFolderPath
                                                             error:&deleteError];
    if (!result) {
        CPLog(@"Error deleting current package contents at %@ error %@", currentPackageFolderPath, deleteError);
    }
    
    [info setValue:info[@"previousPackage"] forKey:@"currentPackage"];
    [info removeObjectForKey:@"previousPackage"];
    
    [self updateCurrentPackageInfo:info error:&error];
}

+ (BOOL)updateCurrentPackageInfo:(NSDictionary *)packageInfo
                           error:(NSError **)error
{
    NSData *packageInfoData = [NSJSONSerialization dataWithJSONObject:packageInfo
                                                              options:0
                                                                error:error];
    if (!packageInfoData) {
        return NO;
    }
    
    NSString *packageInfoString = [[NSString alloc] initWithData:packageInfoData
                                                        encoding:NSUTF8StringEncoding];
    BOOL result = [packageInfoString writeToFile:[self getStatusFilePath]
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding
                                           error:error];
    
    if (!result) {
        return NO;
    }
    return YES;
}

@end
