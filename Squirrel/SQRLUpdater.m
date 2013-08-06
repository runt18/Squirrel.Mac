//
//  SQRLUpdater.m
//  Squirrel
//
//  Created by Justin Spahr-Summers on 2013-07-21.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLUpdater.h"
#import "NSError+SQRLVerbosityExtensions.h"
#import "SQRLArguments.h"
#import "SQRLCodeSignatureVerification.h"

#import "SSZipArchive.h"

NSString * const SQRLUpdaterUpdateAvailableNotification = @"SQRLUpdaterUpdateAvailableNotification";
NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey = @"SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey";
NSString * const SQRLUpdaterUpdateAvailableNotificationReleaseNameKey = @"SQRLUpdaterUpdateAvailableNotificationReleaseNameKey";
NSString * const SQRLUpdaterUpdateAvailableNotificationLulzURLKey = @"SQRLUpdaterUpdateAvailableNotificationLulzURLKey";

static NSString * const SQRLUpdaterAPIEndpoint = @"https://central.github.com/api/mac/latest";
static NSString * const SQRLUpdaterJSONURLKey = @"url";
static NSString * const SQRLUpdaterJSONReleaseNotesKey = @"notes";
static NSString * const SQRLUpdaterJSONNameKey = @"name";

@interface SQRLUpdater ()

@property (atomic, readwrite) SQRLUpdaterState state;

// A serial operation queue for update checks.
@property (nonatomic, strong, readonly) NSOperationQueue *updateQueue;

// A timer used to poll for updates.
@property (nonatomic, strong) NSTimer *updateTimer;

// The folder into which the latest update will be/has been downloaded.
@property (nonatomic, strong) NSURL *downloadFolder;

@end

@implementation SQRLUpdater

#pragma mark Lifecycle

+ (instancetype)sharedUpdater {
	static SQRLUpdater *sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedInstance = [[self alloc] init];
	});
	
	return sharedInstance;
}

- (instancetype)init {
	self = [super init];
	if (self == nil) return nil;
	
	_updateQueue = [[NSOperationQueue alloc] init];
	self.updateQueue.maxConcurrentOperationCount = 1;
	self.updateQueue.name = @"com.github.Squirrel.updateCheckingQueue";
	
	return self;
}

#pragma mark Update Timer

- (void)setUpdateTimer:(NSTimer *)updateTimer {
	if (self.updateTimer == updateTimer) return;
	[self.updateTimer invalidate];
	_updateTimer = updateTimer;
}

- (void)startAutomaticChecksWithInterval:(NSTimeInterval)interval {
	@weakify(self);
	dispatch_async(dispatch_get_main_queue(), ^{
		@strongify(self)
		if (self == nil) return;
		self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(checkForUpdates) userInfo:nil repeats:YES];
	});
}

#pragma mark System Information

- (NSURL *)applicationSupportURL {
	NSString *path = nil;
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
	path = (paths.count > 0 ? paths[0] : NSTemporaryDirectory());
	
	NSString *appDirectoryName = NSBundle.mainBundle.bundleIdentifier;
	NSURL *appSupportURL = [[NSURL fileURLWithPath:path] URLByAppendingPathComponent:appDirectoryName];
	
	NSFileManager *fileManager = [[NSFileManager alloc] init];

	NSError *error = nil;
	BOOL success = [fileManager createDirectoryAtPath:appSupportURL.path withIntermediateDirectories:YES attributes:nil error:&error];
	if (!success) {
		NSLog(@"Error creating Application Support folder: %@", error.sqrl_verboseDescription);
	}
	
	return appSupportURL;
}

- (NSString *)OSVersionString {
	NSURL *versionPlistURL = [NSURL fileURLWithPath:@"/System/Library/CoreServices/SystemVersion.plist"];
	NSDictionary *versionPlist = [NSDictionary dictionaryWithContentsOfURL:versionPlistURL];
	return versionPlist[@"ProductUserVisibleVersion"];
}

#pragma mark Checking

- (void)checkForUpdates {
	if (getenv("DISABLE_UPDATE_CHECK") != NULL) return;
	
	if (self.state != SQRLUpdaterStateIdle) return; //We have a new update installed already, you crazy fool!
	self.state = SQRLUpdaterStateCheckingForUpdate;
	
	NSString *appVersion = NSBundle.mainBundle.infoDictionary[(id)kCFBundleVersionKey];
	NSString *OSVersion = self.OSVersionString;
	
	NSMutableString *requestString = [NSMutableString stringWithFormat:@"%@?version=%@&os_version=%@", SQRLUpdaterAPIEndpoint, [appVersion stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding], [OSVersion stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
	if (self.githubUsername.length > 0) {
		CFStringRef escapedUsername = CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)self.githubUsername, NULL, CFSTR("?=&/#,\\"), kCFStringEncodingUTF8);
		[requestString appendFormat:@"&username=%@", CFBridgingRelease(escapedUsername)];
	}
	
	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:requestString]];
	@weakify(self);
	
	[NSURLConnection sendAsynchronousRequest:request queue:self.updateQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
		@strongify(self);
		
		NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		if (response == nil || ![JSON isKindOfClass:NSDictionary.class]) { //No updates for us
			NSLog(@"Instead of update information, server returned:\n%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);

			[self finishAndSetIdle];
			return;
		}
		
		NSString *urlString = JSON[SQRLUpdaterJSONURLKey];
		if (urlString == nil) { //Hmm… we got returned something without a URL, whatever it is… we aren't interested in it.
			NSLog(@"Update JSON is missing a URL: %@", JSON);

			[self finishAndSetIdle];
			return;
		}

		NSFileManager *fileManager = NSFileManager.defaultManager;
		
		NSString *tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.github.github"];
		NSError *directoryCreationError = nil;
		if (![fileManager createDirectoryAtURL:[NSURL fileURLWithPath:tempDirectory] withIntermediateDirectories:YES attributes:nil error:&directoryCreationError]) {
			NSLog(@"Could not create directory at: %@ because of: %@", self.downloadFolder, directoryCreationError.sqrl_verboseDescription);
			[self finishAndSetIdle];
			return;
		}
		
		NSString *tempDirectoryTemplate = [tempDirectory stringByAppendingPathComponent:@"update.XXXXXXX"];
		
		char *tempDirectoryNameCString = strdup(tempDirectoryTemplate.fileSystemRepresentation);
		@onExit {
			free(tempDirectoryNameCString);
		};
		
		char *result = mkdtemp(tempDirectoryNameCString);
		if (result == NULL) {
			NSLog(@"Could not create temporary directory. Bailing."); //this would be bad
			[self finishAndSetIdle];
			return;
		}
		
		NSString *tempDirectoryPath = [fileManager stringWithFileSystemRepresentation:tempDirectoryNameCString length:strlen(result)];
		
		NSString *releaseNotes = JSON[SQRLUpdaterJSONReleaseNotesKey];
		NSString *lulzURLString = JSON[@"lulz"] ?: [self randomLulzURLString];
		
		self.downloadFolder = [NSURL fileURLWithPath:tempDirectoryPath];
		
		NSURL *zipDownloadURL = [NSURL URLWithString:urlString];
		NSURL *zipOutputURL = [self.downloadFolder URLByAppendingPathComponent:zipDownloadURL.lastPathComponent];
		
		NSURLRequest *zipDownloadRequest = [NSURLRequest requestWithURL:zipDownloadURL];
		
		[NSURLConnection sendAsynchronousRequest:zipDownloadRequest queue:self.updateQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
			@strongify(self);

			if (response == nil) {
				[self finishAndSetIdle];
				return;
			}
			
			if (![data writeToURL:zipOutputURL atomically:YES]) {
				[self finishAndSetIdle];
				return;
			}
			
			NSLog(@"Download completed to: %@", zipOutputURL);
			self.state = SQRLUpdaterStateUnzippingUpdate;
			
			NSURL *destinationURL = zipOutputURL.URLByDeletingLastPathComponent;
			
			BOOL unzipped = [SSZipArchive unzipFileAtPath:zipOutputURL.path toDestination:destinationURL.path];
			if (!unzipped) {
				NSLog(@"Could not extract update.");
				[self finishAndSetIdle];
				return;
			}
			
			NSURL *bundleLocation = [destinationURL URLByAppendingPathComponent:@"GitHub.app"];
			
			NSError *error = nil;
			BOOL verified = [SQRLCodeSignatureVerification verifyCodeSignatureOfBundle:bundleLocation error:&error];
			if (!verified) {
				NSLog(@"Failed to validate the code signature for app update. Error: %@", error.sqrl_verboseDescription);
				[self finishAndSetIdle];
				return;
			}
			
			NSString *name = JSON[SQRLUpdaterJSONNameKey];
			NSDictionary *userInfo = @{
				SQRLUpdaterUpdateAvailableNotificationReleaseNotesKey: releaseNotes,
				SQRLUpdaterUpdateAvailableNotificationReleaseNameKey: name,
				SQRLUpdaterUpdateAvailableNotificationLulzURLKey: [NSURL URLWithString:lulzURLString],
			};
			
			self.state = SQRLUpdaterStateAwaitingRelaunch;
			
			dispatch_async(dispatch_get_main_queue(), ^{
				[NSNotificationCenter.defaultCenter postNotificationName:SQRLUpdaterUpdateAvailableNotification object:self userInfo:userInfo];
			});
		}];
		
		self.state = SQRLUpdaterStateDownloadingUpdate;
	}];
}

- (NSString *)randomLulzURLString {
	NSArray *lulz = @[
		@"http://blog.lmorchard.com/wp-content/uploads/2013/02/well_done_sir.gif",
		@"http://i255.photobucket.com/albums/hh150/hayati_h2/tumblr_lfmpar9EUd1qdzjnp.gif",
		@"http://media.tumblr.com/tumblr_lv1j4x1pJM1qbewag.gif",
		@"http://i.imgur.com/UmpOi.gif",
	];
	return lulz[arc4random() % lulz.count];
}

- (void)finishAndSetIdle {
	if (self.downloadFolder != nil) {
		NSError *deleteError = nil;
		if (![NSFileManager.defaultManager removeItemAtURL:self.downloadFolder error:&deleteError]) {
			NSLog(@"Error removing downloaded update at %@, error: %@", self.downloadFolder, deleteError.sqrl_verboseDescription);
		}
		
		self.downloadFolder = nil;
	}
	
	self.shouldRelaunch = NO;
	self.state = SQRLUpdaterStateIdle;
}

- (void)installUpdateIfNeeded {
	if (self.state != SQRLUpdaterStateAwaitingRelaunch || self.downloadFolder == nil) return;
	
	NSBundle *bundle = [NSBundle bundleForClass:self.class];
	
	NSURL *relauncherURL = [bundle URLForResource:@"shipit" withExtension:nil];
	NSURL *targetURL = [self.applicationSupportURL URLByAppendingPathComponent:@"shipit"];
	NSError *error = nil;
	NSLog(@"Copying relauncher from %@ to %@", relauncherURL, targetURL);
	
	if (![NSFileManager.defaultManager createDirectoryAtURL:targetURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]) {
		NSLog(@"Error installing update, failed to create App Support folder with error %@", error.sqrl_verboseDescription);
		[self finishAndSetIdle];
		return;
	}
	
	if (![NSFileManager.defaultManager removeItemAtURL:targetURL error:&error]) {
		NSLog(@"Error removing existing relauncher binary at %@: %@", targetURL, error.sqrl_verboseDescription);
		[self finishAndSetIdle];
		return;
	}
	
	if (![NSFileManager.defaultManager copyItemAtURL:relauncherURL toURL:targetURL error:&error]) {
		NSLog(@"Error installing update, failed to copy relauncher from %@ to %@: %@", relauncherURL, targetURL, error.sqrl_verboseDescription);
		[self finishAndSetIdle];
		return;
	}
	
	NSMutableArray *arguments = [[NSMutableArray alloc] init];
	void (^addArgument)(NSString *, NSString *) = ^(NSString *key, NSString *stringValue) {
		NSCParameterAssert(key != nil);
		NSCParameterAssert(stringValue != nil);

		[arguments addObject:[@"-" stringByAppendingString:key]];
		[arguments addObject:stringValue];
	};

	NSRunningApplication *currentApplication = NSRunningApplication.currentApplication;
	addArgument(SQRLProcessIdentifierArgumentName, [NSString stringWithFormat:@"%i", currentApplication.processIdentifier]);
	addArgument(SQRLBundleIdentifierArgumentName, currentApplication.bundleIdentifier);
	addArgument(SQRLTargetBundleURLArgumentName, currentApplication.bundleURL.absoluteString);

	addArgument(SQRLUpdateBundleURLArgumentName, [self.downloadFolder URLByAppendingPathComponent:@"GitHub.app"].absoluteString);
	addArgument(SQRLBackupURLArgumentName, self.applicationSupportURL.absoluteString);
	addArgument(SQRLShouldRelaunchArgumentName, (self.shouldRelaunch ? @"1" : @"0"));

	NSTask *launchTask = [[NSTask alloc] init];
	launchTask.launchPath = targetURL.path;
	launchTask.arguments = arguments;
	launchTask.environment = @{};
	[launchTask launch];
}

@end

