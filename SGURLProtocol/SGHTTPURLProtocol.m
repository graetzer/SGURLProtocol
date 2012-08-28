//
//  SGURLProtocol.m
//  SGProtocol
//
//  Created by Simon Grätzer on 25.08.12.
//  Copyright (c) 2012 Simon Grätzer. All rights reserved.
//

#import "SGURLProtocol.h"
#import "SGHTTPURLResponse.h"
#import "SGHTTPAuthenticationChallenge.h"
#import "NSData+Compress.h"

static BOOL							TrustSelfSignedCertificates  = NO;
static NSInteger					RegisterCount				 = 0;
static NSLock*                      VariableLock                 = nil;

@implementation SGURLProtocol
@synthesize buffer = _buffer;

+ (void)load {
    VariableLock = [[NSLock alloc] init];
}

+ (void)registerProtocol {
	[VariableLock lock];
	if (RegisterCount==0) {
        [NSURLProtocol registerClass:[self class]];
	}
	RegisterCount++;
	[VariableLock unlock];
}

+ (void)unregisterProtocol {
	[VariableLock lock];
	RegisterCount--;
	if (RegisterCount==0) {
		[NSURLProtocol unregisterClass:[self class]];
	}
	[VariableLock unlock];
}

+ (void) setTrustSelfSignedCertificates:(BOOL)Trust{
	[VariableLock lock];
	TrustSelfSignedCertificates = Trust;
	[VariableLock unlock];
}

+ (BOOL) getTrustSelfSignedCertificates{
	[VariableLock lock];
	return TrustSelfSignedCertificates;
	[VariableLock unlock];
}


#pragma mark - NSURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{
    NSString *scheme = [[[request URL] scheme] lowercaseString];
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (id)initWithRequest:(NSURLRequest *)request
       cachedResponse:(NSCachedURLResponse *)cachedResponse
               client:(id<NSURLProtocolClient>)client {
    DLog(@"%@", request);
    if (self = [super initWithRequest:request
                cachedResponse:cachedResponse
                        client:client]) {
        _HTTPMessage = [self newMessageWithURLRequest:request];
    }
    return self;
}

- (void)dealloc {
    self.HTTPStream = nil;
    CFRelease(_HTTPMessage);
    NSAssert(!_HTTPStream, @"Deallocating HTTP connection while stream still exists");
    NSAssert(!_authChallenge, @"HTTP connection deallocated mid-authentication");
}

- (void)startLoading {
    if (_HTTPStream) {
        [self stopLoading];
    }
    NSAssert(_HTTPStream == nil, @"HTTPStream is not nil, connection still ongoing");
    self.URLResponse = nil;
    
    CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(NULL, _HTTPMessage);
    // Breaks everything
//    NSDictionary *sslSettings = @{ (id)kCFStreamSSLValidatesCertificateChain : (id)kCFBooleanFalse };
//    CFReadStreamSetProperty(stream,
//                            kCFStreamPropertySSLSettings,
//                            (__bridge CFTypeRef)(sslSettings));
    CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanFalse);

    _HTTPStream = (__bridge NSInputStream *)(stream);
    [_HTTPStream setDelegate:self];
    [_HTTPStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [_HTTPStream open];
}

- (void)stopLoading {
    // Support method to cancel the HTTP stream, but not change the delegate. Used for:
    //  A) Cancelling the connection
    //  B) Waiting to restart the connection while authentication takes place
    //  C) Restarting the connection after an HTTP redirect
    [_HTTPStream close];
    _HTTPStream = nil;
}

#pragma mark - CFStreamDelegate
- (void)stream:(NSInputStream *)theStream handleEvent:(NSStreamEvent)streamEvent
{
    NSParameterAssert(theStream == _HTTPStream);
    
    // Handle the response as soon as it's available
    if (!self.URLResponse)
    {
        CFHTTPMessageRef response = (__bridge CFHTTPMessageRef)[theStream propertyForKey:(NSString *)kCFStreamPropertyHTTPResponseHeader];
        if (response && CFHTTPMessageIsHeaderComplete(response))
        {
#ifdef DEBUG
            CFHTTPMessageRef request = (__bridge CFHTTPMessageRef)([theStream propertyForKey:(NSString *)kCFStreamPropertyHTTPFinalRequest]);
            NSDictionary *headers = (__bridge NSDictionary *)CFHTTPMessageCopyAllHeaderFields(request);
            DLog(@"Request headers: %@", headers);
#endif
            
            // Construct a NSURLResponse object from the HTTP message
            NSURL *URL = [theStream propertyForKey:(NSString *)kCFStreamPropertyHTTPFinalURL];
            NSHTTPURLResponse *HTTPResponse = [NSHTTPURLResponse responseWithURL:URL HTTPMessage:response];
            self.URLResponse = HTTPResponse;
            [self handleCookiesWithURLResponse:HTTPResponse];
            
            NSUInteger code = [HTTPResponse statusCode];
            // If the response was an authentication failure, try to request fresh credentials.
            if (code == 401 || code == 407)
            {
                // Cancel any further loading and ask the delegate for authentication
                [self stopLoading];
                
                NSAssert(!self.authChallenge,
                         @"Authentication challenge received while another is in progress");
                self.authChallenge = [[SGHTTPAuthenticationChallenge alloc] initWithResponse:response
                                                                                proposedCredential:nil
                                                                              previousFailureCount:_authenticationAttempts
                                                                                   failureResponse:HTTPResponse
                                                                                            sender:self];

                if (self.authChallenge) {
                    _authenticationAttempts++;
                    [self.client URLProtocol:self didReceiveAuthenticationChallenge:self.authChallenge];
                    return; // Stops the delegate being sent a response received message
                }
            } else if (code == 301 ||code == 302 || code == 303) {
                // http://en.wikipedia.org/wiki/HTTP_301 Handle 301 only if GET or HEAD
                // TODO: Maybe implement 301 differently.
                
                NSString *location = [HTTPResponse.allHeaderFields objectForKey:@"Location"];
                NSURL *nextURL = [NSURL URLWithString:location relativeToURL:URL];
                if (nextURL) {
                    DLog(@"Redirect to %@", location);
                    NSURLRequest *nextRequest = [NSURLRequest requestWithURL:nextURL
                                                                 cachePolicy:self.request.cachePolicy
                                                             timeoutInterval:self.request.timeoutInterval];
                    
                    [self stopLoading];
                    [self.client URLProtocol:self wasRedirectedToRequest:nextRequest redirectResponse:HTTPResponse];
                    //[self.client URLProtocol:self didReceiveResponse:HTTPResponse cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                    //[self.client URLProtocolDidFinishLoading:self];
                    return;
                }
            } else if (code == 307 || code == 308) {
                NSString *location = [HTTPResponse.allHeaderFields objectForKey:@"Location"];
                NSURL *nextURL = [NSURL URLWithString:location relativeToURL:URL];
                
                // If URL is valid, else just show the page
                if (nextURL) {
                    DLog(@"Redirect to %@", location);
                    NSMutableURLRequest *nextRequest = [self.request mutableCopy];
                    [nextRequest setURL:nextURL];
                    
                    [self stopLoading];
                    [self.client URLProtocol:self wasRedirectedToRequest:nextRequest redirectResponse:HTTPResponse];
                    return;
                }
            } else if (code == 304) { // Handle cached stuff
                NSCachedURLResponse *cached = self.cachedResponse;
                if (!cached) {
                    cached = [[NSURLCache sharedURLCache] cachedResponseForRequest:self.request];
                }
                
                [self.client URLProtocol:self cachedResponseIsValid:cached];
                [self.client URLProtocol:self didLoadData:[cached data]];
                //actually no body expected, TODO: testing
                [self.client URLProtocolDidFinishLoading:self];
                return;
            }
            
            [self.client URLProtocol:self didReceiveResponse:self.URLResponse cacheStoragePolicy:NSURLCacheStorageAllowed];
        }
    }
    
    // Next course of action depends on what happened to the stream
    switch (streamEvent)
    {
            
        case NSStreamEventOpenCompleted:
            self.buffer = [[NSMutableData alloc] initWithCapacity:1024*1024];
            break;
            
        case NSStreamEventHasBytesAvailable:
        {
            while ([theStream hasBytesAvailable])
            {
                uint8_t buf[1024];
                NSUInteger len = [theStream read:buf maxLength:1024];
                [self.buffer appendBytes:(const void *)buf length:len];
                //DLog(@"Written bytes: %i", len);
            }
            break;
        }
            
        case NSStreamEventEndEncountered:{   // Report the end of the stream to the delegate
            NSString *encoding = [self.URLResponse.allHeaderFields objectForKey:@"Content-Encoding"];
            if ([encoding isEqualToString:@"gzip"]) {
                NSData *uncompressed = [self.buffer gzipInflate];
                [self.client URLProtocol:self didLoadData:uncompressed];
            } else if ([encoding isEqualToString:@"deflate"]) {
                NSData *uncompressed = [self.buffer zlibInflate];
                [self.client URLProtocol:self didLoadData:uncompressed];
            } else {
                [self.client URLProtocol:self didLoadData:self.buffer];
            }
            [self.client URLProtocolDidFinishLoading:self];
            break;
        }
            
        case NSStreamEventErrorOccurred:{    // Report an error in the stream as the operation failing
            ELog(@"An error occured")
            [self.client URLProtocol:self didFailWithError:[theStream streamError]];
            break;
        }
            
        default: {
            DLog(@"Error: Unhandled event %i", streamEvent);
        }
    }
}

#pragma mark - Helper

- (NSUInteger)lengthOfDataSent
{
    return [[_HTTPStream propertyForKey:(NSString *)kCFStreamPropertyHTTPRequestBytesWrittenCount] unsignedIntValue];
}

- (CFHTTPMessageRef)newMessageWithURLRequest:(NSURLRequest *)request {
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL,
                                              (__bridge CFStringRef)[request HTTPMethod],
                                              (__bridge CFURLRef)[request URL],
                                              kCFHTTPVersion1_1);
    for (NSString *key in request.allHTTPHeaderFields) {
        NSString *val = [request.allHTTPHeaderFields objectForKey:key];
        CFHTTPMessageSetHeaderFieldValue(message,
                                         (__bridge CFStringRef)key,
                                         (__bridge CFStringRef)val);
    }
    
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Host"), (__bridge CFStringRef)request.URL.host);
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Accept-Charset"), CFSTR("utf-8, ISO-8859-1;q=0.7"));
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Accept-Encoding"), CFSTR("gzip;q=1.0, deflate;q=0.6, identity;q=0.5, *;q=0"));
    //CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Cache-Control"), CFSTR("Keep-Alive"));
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Connection"), CFSTR("Keep-Alive"));

    if (request.HTTPShouldHandleCookies) {
        NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSURL *url = request.URL;//request.mainDocumentURL; ? request.mainDocumentURL : 
        NSArray *cookies = [cookieStorage cookiesForURL:url];
        NSDictionary *headers = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
        for (NSString *key in headers) {
            NSString *val = [headers objectForKey:key];
            CFHTTPMessageSetHeaderFieldValue(message,
                                             (__bridge CFStringRef)key,
                                             (__bridge CFStringRef)val);
        }

    }
        
    NSData *body = [request HTTPBody];
    if (body)
    {
        CFHTTPMessageSetBody(message, (__bridge CFDataRef)body);
    }
    return message;
}

- (void)handleCookiesWithURLResponse:(NSHTTPURLResponse *)response {
    NSString *cookieString = [response.allHeaderFields objectForKey:@"Set-Cookie"];
    if (cookieString) {
        NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields
                                                                  forURL:response.URL];
        [cookieStorage setCookies:cookies
                           forURL:response.URL
                  mainDocumentURL:self.request.mainDocumentURL];
    }
}

#pragma mark - Authentication

- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    NSParameterAssert(challenge == [self authChallenge]);
    self.authChallenge = nil;
    
    [self.client URLProtocol:self didCancelAuthenticationChallenge:challenge];
    [self.client URLProtocol:self didFailWithError:challenge.error];
    
    [self.client URLProtocol:self didReceiveResponse:[challenge failureResponse] cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    // Treat like a -cancel message
    [self stopLoading];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    //[self cancelAuthenticationChallenge:challenge];
    [self cancelAuthenticationChallenge:self];
}

- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    NSParameterAssert(challenge == [self authChallenge]);
    self.authChallenge = nil;
    
    // Retry the request, this time with authentication // TODO: What if this function fails?
    CFHTTPAuthenticationRef HTTPAuthentication = [(SGHTTPAuthenticationChallenge *)challenge CFHTTPAuthentication];
    CFHTTPMessageApplyCredentials(_HTTPMessage,
                                  HTTPAuthentication,
                                  (__bridge CFStringRef)[credential user],
                                  (__bridge CFStringRef)[credential password],
                                  NULL);
    [self startLoading];
}

-  (void)performDefaultHandlingForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    [self cancelAuthenticationChallenge:challenge];
}

- (void)rejectProtectionSpaceAndContinueWithChallenge:(NSURLAuthenticationChallenge *)challenge {
    [self cancelAuthenticationChallenge:challenge];
}

@end



#pragma mark -




