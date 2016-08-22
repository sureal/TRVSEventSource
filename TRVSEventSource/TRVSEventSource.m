//
//  TRVSEventSourceManager.m
//  TRVSEventSource
//
//  Created by Travis Jeffery on 10/8/13.
//  Copyright (c) 2013 Travis Jeffery. All rights reserved.
//

#import "TRVSEventSource.h"

static NSUInteger const TRVSEventSourceListenersCapacity = 100;
static NSString *const TRVSEventSourceOperationQueueName = @"com.travisjeffery.TRVSEventSource.operationQueue";

NSString *const TRVSEventSourceHttpStatus = @"HTTPStatus";
NSString *const TRVSEventSourceErrorContent = @"ErrorContent";

typedef NS_ENUM(NSUInteger, TRVSEventSourceState) {
    TRVSEventSourceConnecting = 0,
    TRVSEventSourceOpen,
    TRVSEventSourceClosed,
    TRVSEventSourceClosing,
    TRVSEventSourceFailed
};


@interface TRVSEventSource ()
// Private writable, public readable
@property(nonatomic, strong, readwrite) NSURL *URL;
@property(nonatomic, strong, readwrite) NSURLSession *URLSession;
@property(nonatomic, strong, readwrite) NSURLSessionTask *URLSessionTask;
@property(nonatomic, strong, readwrite) NSOperationQueue *operationQueue;

// Private
@property(nonatomic) TRVSEventSourceState state;
@property(nonatomic, strong) NSMapTable *listenersKeyedByEvent;
@property(nonatomic, strong) NSMutableString *buffer;

- (NSDictionary *)extractSSEFieldsFromString:(NSString *)string withError:(NSError *__autoreleasing *) error;

@end

// Mark this class only internally as a URL session data delegate
@interface TRVSEventSource (sessionDataDelegate) <NSURLSessionDataDelegate>
@end

@implementation TRVSEventSource

#pragma mark - Construction

- (instancetype)initWithURL:(NSURL *)URL {
    return [self initWithURL:URL
        sessionConfiguration:NSURLSessionConfiguration
                .defaultSessionConfiguration];
}

- (instancetype)initWithURL:(NSURL *)URL
       sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
    if (!(self = [super init])) {
        return nil;
    }

    self.operationQueue = [[NSOperationQueue alloc] init];
    self.operationQueue.name = TRVSEventSourceOperationQueueName;
	self.operationQueue.maxConcurrentOperationCount = 1;
    self.URL = URL;
    self.listenersKeyedByEvent =
            [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsCopyIn
                                      valueOptions:NSPointerFunctionsStrongMemory
                                          capacity:TRVSEventSourceListenersCapacity];

    self.URLSession = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                    delegate:self
                                               delegateQueue:self.operationQueue];

    self.buffer = [NSMutableString stringWithCapacity:4096];

    return self;
}


#pragma mark - Event Source Control

- (void)open {
    [self transitionToConnecting];
}

- (void)close {
    [self transitionToClosing];
}


#pragma mark - Event Listener Registration

- (NSUInteger)addListenerForEvent:(NSString *)event
                usingEventHandler:(TRVSEventSourceEventHandler)eventHandler {

    NSMutableDictionary *mutableListenersKeyedByIdentifier = [self.listenersKeyedByEvent objectForKey:event];

    if (!mutableListenersKeyedByIdentifier) {
        mutableListenersKeyedByIdentifier = [NSMutableDictionary dictionary];
    }

    NSUInteger identifier = [[NSUUID UUID] hash];
    mutableListenersKeyedByIdentifier[@(identifier)] = [eventHandler copy];

    [self.listenersKeyedByEvent setObject:mutableListenersKeyedByIdentifier
                                   forKey:event];

    return identifier;
}

- (void)removeEventListenerWithIdentifier:(NSUInteger)identifier {

    NSEnumerator *enumerator = [self.listenersKeyedByEvent keyEnumerator];
    id event = nil;

    while ((event = [enumerator nextObject])) {
        NSMutableDictionary *mutableListenersKeyedByIdentifier = [self.listenersKeyedByEvent objectForKey:event];

        if ([mutableListenersKeyedByIdentifier objectForKey:@(identifier)]) {

            [mutableListenersKeyedByIdentifier removeObjectForKey:@(identifier)];

            [self.listenersKeyedByEvent setObject:mutableListenersKeyedByIdentifier
                                           forKey:event];
            return;
        }
    }
}

- (void)removeAllListenersForEvent:(NSString *)event {
    [self.listenersKeyedByEvent removeObjectForKey:event];
}


#pragma mark - Event Source State

- (BOOL)isConnecting {
    return self.state == TRVSEventSourceConnecting;
}

- (BOOL)isOpen {
    return self.state == TRVSEventSourceOpen;
}

- (BOOL)isClosed {
    return self.state == TRVSEventSourceClosed;
}

- (BOOL)isClosing {
    return self.state == TRVSEventSourceClosing;
}

#pragma mark - NSURLSessionTaskDelegate (parent of NSURLSessionDataDelegate)


- (void)  URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {

    // "Sent as the last message related to a specific task.  Error may be nil,
    // which implies that no error occurred and this task is complete."

    if (self.isClosing && error && error.code == NSURLErrorCancelled) {
        [self transitionToClosed];
    } else {

        // If no error was passed, the session has just closed
        if(!error) {

//            NSLog(@"TRVSEventSource URLSession did complete with Error but with Error = nil. Close session.");
            [self transitionToClosed];
        } else {
            [self transitionToFailedWithError:error];
        }
    }
}


#pragma mark - NSURLSessionDataDelegate


- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {

    // Decode received data to string
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    // Check for HTTP Status code different to 200 - OK
    // If not 200, fail with error (Super simple handling without automatic async. reconnect attempts (as suggested in http://www.w3.org/TR/eventsource/#processing-model)
    if([dataTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse* httpURLResponse = (NSHTTPURLResponse *) dataTask.response;
        NSInteger httpStatus = httpURLResponse.statusCode;
        if(httpStatus != 200) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setValue:@(httpStatus) forKey:TRVSEventSourceHttpStatus];
            [userInfo setValue:string forKey:TRVSEventSourceErrorContent];
            NSError *receivedError = [NSError errorWithDomain:@"HTTP Error" code:httpStatus userInfo:userInfo];

            // propagate error
            [self transitionToFailedWithError:receivedError];
            // stop processing
            return;
        }
    }

    // Append received stream part as a string to the string buffer
    [self.buffer appendString:string];

    // Interpretation: double CR/LF is interpreted as the end (or begin??) of a event, hence it may be propagated
    NSRange range = [self.buffer rangeOfString:@"\n\n"];

    NSError *error = nil;
    TRVSServerSentEvent *event = nil;

    while (range.location != NSNotFound)
        @autoreleasepool {
            error = nil;
            NSString *eventPortion = [self.buffer substringToIndex:range.location];
            NSDictionary *eventFields = [self extractSSEFieldsFromString:eventPortion withError:&error];
            event = [TRVSServerSentEvent eventWithFields:eventFields];

            // consume converted characters from buffer
            [self.buffer deleteCharactersInRange:NSMakeRange(0, range.location + 2)];

            // if SSE Event field extraction failed
            if (error) {
                [self transitionToFailedWithError:error];
            }

            if (error || !event) {
                return;
            }

            // If the event was received completely and a event object was created, propagate it to registrations (per EVENT kind)
            [[self.listenersKeyedByEvent objectForKey:event.event]
                    enumerateKeysAndObjectsUsingBlock:
                            ^(id _, TRVSEventSourceEventHandler eventHandler, BOOL *stop) {
                                eventHandler(event, nil);
                            }];

            // Generally propagate that a event was found (any kind)
            if ([self.delegate
                    respondsToSelector:@selector(eventSource:didReceiveEvent:)]) {
                [self.delegate eventSource:self didReceiveEvent:event];
            }

            // update event range in buffer
            range = [self.buffer rangeOfString:@"\n\n"];
        }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {

    /* Allow the load to continue */
    completionHandler(NSURLSessionResponseAllow);

    [self transitionToOpenIfNeeded];
}



#pragma NSCoding

- (id)initWithCoder:(NSCoder *)aDecoder {
    NSURL *URL = [aDecoder decodeObjectForKey:@"URL"];

    if (!(self = [self initWithURL:URL])) {
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.URL forKey:@"URL"];
}

#pragma NSCopying

- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithURL:self.URL];
}



#pragma mark - State Transitions

- (void)transitionToConnecting {
    self.state = TRVSEventSourceConnecting;
    [self.operationQueue addOperationWithBlock:^{
        [self.buffer setString:@""];
    }];
    self.URLSessionTask = [self.URLSession dataTaskWithURL:self.URL];
    [self.URLSessionTask resume];
}

- (void)transitionToOpenIfNeeded {
    if (self.state != TRVSEventSourceConnecting)
        return;

    self.state = TRVSEventSourceOpen;

    if ([self.delegate respondsToSelector:@selector(eventSourceDidOpen:)]) {
        [self.delegate eventSourceDidOpen:self];
    }
}

- (void)transitionToFailedWithError:(NSError *)error {
    self.state = TRVSEventSourceFailed;

    if ([self.delegate
            respondsToSelector:@selector(eventSource:didFailWithError:)]) {
        [self.delegate eventSource:self didFailWithError:error];
    }
}

- (void)transitionToClosing {
    self.state = TRVSEventSourceClosing;
    [self.operationQueue addOperationWithBlock:^{
        [self.buffer setString:@""];
    }];
    [self.URLSession invalidateAndCancel];
}

- (void)transitionToClosed {
    self.state = TRVSEventSourceClosed;

    if ([self.delegate respondsToSelector:@selector(eventSourceDidClose:)]) {
        [self.delegate eventSourceDidClose:self];
    }
}

#pragma mark - SSE Event Message format interpretation

- (NSDictionary *)extractSSEFieldsFromString:(NSString *)string withError:(NSError *__autoreleasing *) error
{
    if (!string || [string length] == 0)
        return nil;

    NSMutableDictionary *mutableFields = [NSMutableDictionary dictionary];

    for (NSString *line in [string componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        if (!line || [line length] == 0 || [line hasPrefix:@":"])
            continue;

        @autoreleasepool {
            NSScanner *scanner = [[NSScanner alloc] initWithString:line];
            scanner.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];
            NSString *key, *value;
            [scanner scanUpToString:@":" intoString:&key];
            [scanner scanString:@":" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&value];

            if (key && value) {
                if (mutableFields[key]) {
                    mutableFields[key] =
                            [mutableFields[key] stringByAppendingFormat:@"\n%@", value];
                } else {
                    mutableFields[key] = value;
                }
            }
        }
    }

    return mutableFields;
}



@end
