//
//  SQRLDownloadControllerSpec.m
//  Squirrel
//
//  Created by Keith Duncan on 27/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadController.h"
#import "SQRLResumableDownload.h"

SpecBegin(SQRLDownloadController)

__block SQRLDownloadController *downloadController = nil;

beforeAll(^{
	downloadController = SQRLDownloadController.defaultDownloadController;
	[downloadController removeAllResumableDownloads];
});

NSURL * (^newTestURL)() = ^ () {
	return [[NSURL alloc] initWithScheme:@"http" host:@"localhost" path:[@"/" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
};

NSURL * (^newDownloadURL)() = ^ () {
	SQRLResumableDownload *download = [downloadController downloadForURL:newTestURL()];
	expect(download).notTo.beNil();

	NSURL *downloadURL = download.fileURL;
	expect(downloadURL).notTo.beNil();

	return downloadURL;
};

it(@"should return a file that doesn't exist yet for new URLs", ^{
	NSURL *downloadURL = newDownloadURL();

	BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:downloadURL.path];
	expect(exists).to.beFalsy();
});

it(@"should return a path in a writable directory for new URLs", ^{
	NSURL *downloadURL = newDownloadURL();

	BOOL writable = [NSFileManager.defaultManager isWritableFileAtPath:downloadURL.URLByDeletingLastPathComponent.path];
	expect(writable).to.beTruthy();
});

it(@"should return the same path for the same URL", ^{
	NSURL *testURL = newTestURL();

	SQRLResumableDownload *download1 = [downloadController downloadForURL:testURL];
	SQRLResumableDownload *download2 = [downloadController downloadForURL:testURL];
 
	expect(download1).to.equal(download2);
});

it(@"should remember a response", ^{
	NSURL *testURL = newTestURL();
	NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:testURL statusCode:200 HTTPVersion:(__bridge NSString *)kCFHTTPVersion1_1 headerFields:@{ @"ETag": NSProcessInfo.processInfo.globallyUniqueString }];

	SQRLResumableDownload *initialDownload = [downloadController downloadForURL:testURL];

	SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:response fileURL:initialDownload.fileURL];
	[downloadController setDownload:newDownload forURL:testURL];
	expect(initialDownload).notTo.equal(newDownload);

	SQRLResumableDownload *resumedDownload = [downloadController downloadForURL:testURL];
	expect(resumedDownload).to.equal(newDownload);
});

SpecEnd
