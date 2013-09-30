//
//  SQRLResumableDownload.h
//  Squirrel
//
//  Created by Keith Duncan on 30/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import <Foundation/Foundation.h>

// State required to resume a download from where it left off.
@interface SQRLResumableDownload : NSObject <NSCoding>

// Designated initialiser.
//
// response - HTTP response whose body is being downloaded, may be nil.
// fileURL  - local file system location where the download is being saved to,
//            must not be nil.
- (instancetype)initWithResponse:(NSHTTPURLResponse *)response fileURL:(NSURL *)fileURL;

// response initialised with.
@property (readonly, copy, nonatomic) NSHTTPURLResponse *response;

// fileURL initialised with.
@property (readonly, copy, nonatomic) NSURL *fileURL;

@end
