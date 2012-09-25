//
//  SGURLProtocol.h
//  SGProtocol
//
//  Created by Simon Grätzer on 25.08.12.
//  Copyright (c) 2012 Simon Grätzer. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import "SGURLProtocol.h"

@protocol SGAuthDelegate <NSObject>

- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
//
//@optional
//- (void)URLProtocol:(NSURLProtocol *)protocol didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;

@end

@class SGHTTPAuthenticationChallenge;
@interface SGHTTPURLProtocol : NSURLProtocol <NSStreamDelegate, NSURLAuthenticationChallengeSender> {
    CFHTTPMessageRef _HTTPMessage;
    NSInteger                       _authenticationAttempts;
}

@property (strong, nonatomic) NSInputStream *HTTPStream;
@property (strong, nonatomic) NSHTTPURLResponse *URLResponse;
@property (strong, nonatomic) NSMutableData *buffer;
@property (strong, nonatomic) SGHTTPAuthenticationChallenge *authChallenge;

+ (void) registerProtocol;
+ (void) unregisterProtocol;
+ (void) setAuthDelegate:(id<SGAuthDelegate>)delegate;

@end