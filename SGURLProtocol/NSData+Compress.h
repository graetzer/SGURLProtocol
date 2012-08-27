//
//  NSData+Compress.h
//  SGURLProtocol
//
//  Created by Simon Grätzer on 26.08.12.
//  Copyright (c) 2012 Simon Grätzer. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <zlib.h>

@interface NSData (Compress)
- (NSData *)zlibInflate;
- (NSData *)zlibDeflate;

// Decompress
- (NSData *)gzipInflate;
// Compress
- (NSData *)gzipDeflate;
@end
