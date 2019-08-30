//
// Copyright 2010-2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
// http://aws.amazon.com/apache2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//

#import <Security/Security.h>

#import "AWSIoTMQTTClient.h"
#import "AWSMQTTSession.h"
#import "AWSSRWebSocket.h"
#import "AWSIoTWebSocketOutputStream.h"
#import "AWSIoTKeychain.h"

@implementation AWSIoTMQTTTopicModel
@end

@implementation AWSIoTMQTTQueueMessage
@end

@interface AWSIoTMQTTClient() <AWSSRWebSocketDelegate, NSStreamDelegate, AWSMQTTSessionDelegate>

@property(atomic, assign, readwrite) AWSIoTMQTTStatus mqttStatus;
@property(nonatomic, strong) AWSMQTTSession* session;
@property(nonatomic, strong) NSMutableDictionary * topicListeners;

@property(atomic, assign) BOOL userDidIssueDisconnect; //Flag to indicate if requestor has issued a disconnect
@property(atomic, assign) BOOL userDidIssueConnect; //Flag to indicate if requestor has issued a connect

@property(nonatomic, strong) NSString *host;
@property(nonatomic, strong) NSString *presignedURL;
@property(nonatomic, assign) UInt32 port;
@property(nonatomic, assign) BOOL cleanSession; // Flag to clear prior session state upon connect

@property(nonatomic, strong) NSArray *clientCerts;
@property(nonatomic, strong) AWSSRWebSocket *webSocket;
@property(nonatomic, strong) AWSServiceConfiguration *configuration; //Service Configuration to fetch AWS Credentials for direct webSocket connection

@property UInt16 keepAliveInterval;

@property(nonatomic, strong) NSMutableDictionary<NSNumber *, AWSIoTMQTTAckBlock> *ackCallbackDictionary;

@property NSString *lastWillAndTestamentTopic;
@property NSData *lastWillAndTestamentMessage;
@property UInt8 lastWillAndTestamentQoS;
@property BOOL lastWillAndTestamentRetainFlag;

// When AWSIoTMQTTClient receives data from the web socket (via `-[webSocket:didReceiveMessage:]`), it writes data to
// this stream, which is bound to `decoderStream`.
@property(nonatomic, strong) NSOutputStream *toDecoderStream;

// The AWSMQTTSession passes this stream to AWSMQTTDecoder. AWSMQTTDecoder reads from this stream, decodes data, and
// invokes `AWSMQTTDecoderDelegate` methods on its delegate (the AWSMQTTSession).
@property(nonatomic, strong) NSInputStream  *decoderStream;

// The AWSMQTTSession passes this stream to AWSMQTTEncoder. When AWSMQTTSession invokes
// `-[AWSMQTTEncoder encodeMessage:]`, the encoder writes encoded data to this stream, which is a dummy stream that
// actually invokes `-[AWSSRWebSocket send:]`.
@property(nonatomic, strong) NSOutputStream *toWebSocketStream;

@property (nonatomic, copy) void (^connectStatusCallback)(AWSIoTMQTTStatus status);

@property (nonatomic, strong) NSThread *streamsThread;

@property (atomic, assign) BOOL runLoopShouldContinue;

@end

@implementation AWSIoTMQTTClient

/*
 This version is for metrics collection for AWS IoT purpose only. It may be different
 than the version of AWS SDK for iOS. Update this version when there's a change in AWSIoT.
 */
static const NSString *SDK_VERSION = @"2.6.19";


#pragma mark Intialitalizers

- (instancetype)init {
    if (self = [super init]) {
        _topicListeners = [NSMutableDictionary dictionary];
        _clientCerts = nil;
        _session.delegate = nil;
        _session = nil;
        _clientId = nil;
        _associatedObject = nil;
        _autoResubscribe = YES;
        _isMetricsEnabled = YES;
        _ackCallbackDictionary = [NSMutableDictionary new];
        _webSocket = nil;
        _userDidIssueConnect = NO;
        _userDidIssueDisconnect = NO;
        _streamsThread = nil;
    }
    return self;
}

- (instancetype)initWithDelegate:(id<AWSIoTMQTTClientDelegate>)delegate {
    self = [self init];
    if (self) {
        self.clientDelegate = delegate;
    }
    return self;
}

#pragma mark signer methods

- (NSData *)getDerivedKeyForSecretKey:(NSString *)secretKey
                            dateStamp:(NSString *)dateStamp
                           regionName:(NSString *)regionName
                          serviceName:(NSString *)serviceName;
{
    // AWS4 uses a series of derived keys, formed by hashing different pieces of data
    NSString *kSecret = [NSString stringWithFormat:@"AWS4%@", secretKey];
    NSData *kDate = [AWSSignatureSignerUtility sha256HMacWithData:[dateStamp dataUsingEncoding:NSUTF8StringEncoding]
                                                          withKey:[kSecret dataUsingEncoding:NSUTF8StringEncoding]];
    NSData *kRegion = [AWSSignatureSignerUtility sha256HMacWithData:[regionName dataUsingEncoding:NSASCIIStringEncoding]
                                                            withKey:kDate];
    NSData *kService = [AWSSignatureSignerUtility sha256HMacWithData:[serviceName dataUsingEncoding:NSUTF8StringEncoding]
                                                             withKey:kRegion];
    NSData *kSigning = [AWSSignatureSignerUtility sha256HMacWithData:[AWSSignatureV4Terminator dataUsingEncoding:NSUTF8StringEncoding]
                                                             withKey:kService];
    return kSigning;
}

- (NSString *)signWebSocketUrlForMethod:(NSString *)method
                                 scheme:(NSString *)scheme
                               hostName:(NSString *)hostName
                                   path:(NSString *)path
                            queryParams:(NSString *)queryParams
                              accessKey:(NSString *)accessKey
                              secretKey:(NSString *)secretKey
                             regionName:(NSString *)regionName
                            serviceName:(NSString *)serviceName
                                payload:(NSString *)payload
                                  today:(NSString *)today
                                    now:(NSString *)now
                             sessionKey:(NSString *)sessionKey;
{
    NSString *payloadHash = [AWSSignatureSignerUtility hexEncode:[AWSSignatureSignerUtility hashString:payload]];
    NSString *canonicalRequest = [NSString stringWithFormat:@"%@\n%@\n%@\nhost:%@\n\nhost\n%@",
                                  method,
                                  path,
                                  queryParams,
                                  hostName,
                                  payloadHash];
    NSString *hashedCanonicalRequest = [AWSSignatureSignerUtility hexEncode:[AWSSignatureSignerUtility hashString:canonicalRequest]];
    NSString *stringToSign = [NSString stringWithFormat:@"AWS4-HMAC-SHA256\n%@\n%@/%@/%@/%@\n%@",
                              now,
                              today,
                              regionName,
                              serviceName,
                              AWSSignatureV4Terminator,
                              hashedCanonicalRequest];
    NSData *signingKey = [self getDerivedKeyForSecretKey:secretKey dateStamp:today regionName:regionName serviceName:serviceName];
    NSData *signature  = [AWSSignatureSignerUtility sha256HMacWithData:[stringToSign dataUsingEncoding:NSUTF8StringEncoding]
                                                               withKey:signingKey];
    NSString *signatureString = [AWSSignatureSignerUtility hexEncode:[[NSString alloc] initWithData:signature
                                                                                           encoding:NSASCIIStringEncoding]];
    NSString *url = nil;

    if (sessionKey != nil)
    {
        url = [NSString stringWithFormat:@"%@%@%@?%@&X-Amz-Security-Token=%@&X-Amz-Signature=%@",
               scheme,
               hostName,
               path,
               queryParams,
               [sessionKey aws_stringWithURLEncoding],
               signatureString];
    }
    else
    {
        url = [NSString stringWithFormat:@"%@%@%@?%@&X-Amz-Signature=%@",
               scheme,
               hostName,
               path,
               queryParams,
               signatureString];
    }
    return url;
}

- (NSString *)prepareWebSocketUrlWithHostName:(NSString *)hostName
                                   regionName:(NSString *)regionName
                                    accessKey:(NSString *)accessKey
                                    secretKey:(NSString *)secretKey
                                   sessionKey:(NSString *)sessionKey
{
    NSDate *date          = [NSDate aws_clockSkewFixedDate];
    NSString *now         = [date aws_stringValue:AWSDateISO8601DateFormat2];
    NSString *today       = [date aws_stringValue:AWSDateShortDateFormat1];
    NSString *path        = @"/mqtt";
    NSString *serviceName = @"iotdata";
    NSString *algorithm   = @"AWS4-HMAC-SHA256";

    NSString *queryParams = [NSString stringWithFormat:@"X-Amz-Algorithm=%@&X-Amz-Credential=%@%%2F%@%%2F%@%%2F%@%%2Faws4_request&X-Amz-Date=%@&X-Amz-SignedHeaders=host",
                             algorithm,
                             accessKey,
                             today,
                             regionName,
                             serviceName,
                             now];

    return [self signWebSocketUrlForMethod:@"GET"
                                    scheme:@"wss://"
                                  hostName:hostName
                                      path:path
                               queryParams:queryParams
                                 accessKey:accessKey
                                 secretKey:secretKey
                                regionName:regionName
                               serviceName:serviceName
                                   payload:@""
                                     today:today
                                       now:now
                                sessionKey:sessionKey];
}

#pragma mark connect lifecycle methods

- (BOOL) connectWithClientId:(NSString *)clientId
               cleanSession:(BOOL)cleanSession
              configuration:(AWSServiceConfiguration *)configuration
                  keepAlive:(UInt16)theKeepAliveInterval
                  willTopic:(NSString*)willTopic
                    willMsg:(NSData*)willMsg
                    willQoS:(UInt8)willQoS
             willRetainFlag:(BOOL)willRetainFlag
             statusCallback:(void (^)(AWSIoTMQTTStatus status))callback;
{
    if (self.userDidIssueConnect) {
        //Issuing connect multiple times. Not allowed.
        AWSDDLogWarn(@"Connect already in progress, aborting");
        return NO;
    }
    
    //Intialize connection state
    self.userDidIssueDisconnect = NO;
    self.userDidIssueConnect = YES;
    self.session = nil;
    self.cleanSession = cleanSession;
    self.configuration = configuration;
    self.clientId = clientId;
    self.lastWillAndTestamentTopic = willTopic;
    self.lastWillAndTestamentMessage = willMsg;
    self.lastWillAndTestamentQoS = willQoS;
    self.lastWillAndTestamentRetainFlag = willRetainFlag;
    self.keepAliveInterval = theKeepAliveInterval;
    self.connectStatusCallback = callback;
    
    return [self webSocketConnectWithClientId];
}

- (BOOL)connectWithClientId:(NSString *)clientId
               presignedURL:(NSString *)presignedURL
             statusCallback:(void (^)(AWSIoTMQTTStatus status))callback {
    if (clientId != nil && presignedURL != nil) {
        // currently using the last given URL on subscribe call
        self.presignedURL = presignedURL;
        AWSDDLogDebug(@"%s [Line %d], Thread:%@ ", __PRETTY_FUNCTION__, __LINE__, [NSThread currentThread]);
        return [self connectWithClientId:clientId
                            cleanSession:YES
                           configuration:nil
                               keepAlive:300
                               willTopic:nil
                                 willMsg:nil
                                 willQoS:1
                          willRetainFlag:NO
                          statusCallback:callback];
    } else {
        // Invalidate input parameters, return unsuccessfully.
        return NO;
    }
}

- (BOOL) webSocketConnectWithClientId {
    AWSDDLogInfo(@"AWSIoTMQTTClient(%@): connecting via websocket", self.clientId);
    
    if ( self.webSocket ) {
        [self.webSocket close];
        self.webSocket = nil;
    }
    
    if ( ! ( self.clientId != nil && ( self.presignedURL != nil || self.configuration != nil ))) {
        // client ID and one of serviceConfiguration and presignedURL are mandatory and if they haven't been provided, we return with NO to indicate failure.
        return NO;
    }
    
    if (self.presignedURL) {
        dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
            [self initWebSocketConnectionForURL:self.presignedURL];
        });

    } else {
        //Get Credentials from credentials provider.
        [[self.configuration.credentialsProvider credentials] continueWithBlock:^id _Nullable(AWSTask<AWSCredentials *> * _Nonnull task) {
            
            if (task.error) {
                AWSDDLogError(@"(%@) Unable to connect to MQTT due to an error fetching credentials from the Credentials Provider.", self.clientId);
                //Set Connection status to Error.
                self.mqttStatus = AWSIoTMQTTStatusConnectionError;
                //Notify connection status.
                [self notifyConnectionStatus];
                return nil;
            }
            
            //No error. We have credentials.
            AWSCredentials *credentials = task.result;
            
            //Prepare WebSocketURL
            NSString *urlString = [self prepareWebSocketUrlWithHostName:self.configuration.endpoint.hostName
                                                             regionName:self.configuration.endpoint.regionName
                                                              accessKey:credentials.accessKey
                                                              secretKey:credentials.secretKey
                                                             sessionKey:credentials.sessionKey];
            
            [self initWebSocketConnectionForURL:urlString];
            
            return nil;
        }];
    }
    return YES;
}

- (void)initWebSocketConnectionForURL:(NSString *)urlString {
    // Set status to "Connecting"
    self.mqttStatus = AWSIoTMQTTStatusConnecting;
    
    //clear session if required
    if (self.cleanSession) {
        [self.topicListeners removeAllObjects];
    }
    
    //Setup userName if metrics are enabled
    NSString *username;
    if (self.isMetricsEnabled) {
        username = [NSString stringWithFormat:@"%@%@", @"?SDK=iOS&Version=", SDK_VERSION];
        AWSDDLogInfo(@"username is : %@", username);
    }
    AWSDDLogInfo(@"Metrics collection is: %@", self.isMetricsEnabled ? @"Enabled" : @"Disabled");

    //create Session if one doesn't already exist
    if (self.session == nil ) {
        self.session = [[AWSMQTTSession alloc] initWithClientId:self.clientId
                                                       userName:username
                                                       password:@""
                                                      keepAlive:self.keepAliveInterval
                                                   cleanSession:self.cleanSession
                                                      willTopic:self.lastWillAndTestamentTopic
                                                        willMsg:self.lastWillAndTestamentMessage
                                                        willQoS:self.lastWillAndTestamentQoS
                                                 willRetainFlag:self.lastWillAndTestamentRetainFlag
                                           publishRetryThrottle:self.publishRetryThrottle];
        self.session.delegate = self;
    }
    
    //Notify connection status.
    [self notifyConnectionStatus];
    
    //Create the webSocket and setup the MQTTClient object as the delegate
    self.webSocket = [[AWSSRWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]
                                                      protocols:@[@"mqttv3.1"]
                                 allowsUntrustedSSLCertificates:NO];
    self.webSocket.delegate = self;
    
    //Open the web socket
    [self.webSocket open];
    
    // Now that the WebSocket is created and opened, it will send its delegate, i.e., this MQTTclient object the messages.
    AWSDDLogVerbose(@"(%@) Websocket is created and opened", self.clientId);
}

- (void)disconnect {
    if (self.userDidIssueDisconnect ) {
        //Issuing disconnect multiple times. Turn this function into a noop by returning here.
        AWSDDLogWarn(@"(%@) Disconnect already in progress, aborting", self.clientId);
        return;
    }
    
    //Set the userDisconnect flag to true to indicate that the user has initiated the disconnect.
    self.userDidIssueDisconnect = YES;
    self.userDidIssueConnect = NO;
    
    //call disconnect on the session.
    [self.session disconnect];
    
    //Set the flag to signal to the runloop that it can terminate
    self.runLoopShouldContinue = NO;
    
    [self.webSocket close];
    [self.toWebSocketStream close];
    [self.streamsThread cancel];

    self.clientDelegate = nil;
    
    AWSDDLogInfo(@"AWSIoTMQTTClient(%@): Disconnect message issued", self.clientId);
}

- (void) notifyConnectionStatus {
    //Set the connection status on the callback.
    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
        if (self.connectStatusCallback != nil) {
            self.connectStatusCallback(self.mqttStatus);
        }
        
        if (self.clientDelegate != nil) {
            [self.clientDelegate connectionStatusChanged:self.mqttStatus client:self];
        }
    });
}

- (void)openStreams:(id)sender {
    AWSDDLogVerbose(@"(%@) Opening streams", self.clientId);

    //This is invoked in a new thread by the webSocketDidOpen method or by the Connect method. Get the runLoop from the thread.
    NSRunLoop *runLoopForStreamsThread = [NSRunLoop currentRunLoop];
    
    //Setup a default timer to ensure that the RunLoop always has at least one timer on it. This is to prevent the while loop
    //below to spin in tight loop when all input sources and session timers are shutdown during a reconnect sequence.
    NSTimer *defaultRunLoopTimer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:60.0]
                                                            interval:60.0
                                                              target:self
                                                            selector:@selector(timerHandler:)
                                                            userInfo:nil
                                                             repeats:YES];
    [runLoopForStreamsThread addTimer:defaultRunLoopTimer forMode:NSDefaultRunLoopMode];
    
    self.runLoopShouldContinue = YES;
    [self.toDecoderStream scheduleInRunLoop:runLoopForStreamsThread forMode:NSDefaultRunLoopMode];
    [self.toDecoderStream open];
    
    //Update the runLoop and runLoopMode in session.
    [self.session connectToInputStream:self.decoderStream outputStream:self.toWebSocketStream];
    
    while (self.runLoopShouldContinue && NSThread.currentThread.isCancelled == NO) {
        //This will continue to run until runLoopShouldContinue is set to NO during "disconnect" or
        //"websocketDidFail"
        
        //Run one cycle of the runloop. This will return after a input source event or timer event is processed
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        [runLoopForStreamsThread runMode:NSDefaultRunLoopMode beforeDate:[deadline copy]];
    }
    
    // clean up the defaultRunLoopTimer.
    [defaultRunLoopTimer invalidate];
    
    if (!self.runLoopShouldContinue) {
        AWSDDLogVerbose(@"(%@) Cleaning up runloop & streams", self.clientId);
        [self.session close];
    
        //Set status
        self.mqttStatus = AWSIoTMQTTStatusDisconnected;
        
        // Let the client know it has been disconnected.
        [self notifyConnectionStatus];
    }
}

- (void)timerHandler:(NSTimer*)theTimer {
    AWSDDLogVerbose(@"ThreadID: [%@] Default run loop timer executed: runLoopShouldContinue is [%d] and Cancelled is [%d]", [NSThread currentThread], self.runLoopShouldContinue, [[NSThread currentThread] isCancelled]);
}

#pragma mark publish methods

- (void)publishString:(NSString*)str
              onTopic:(NSString*)topic
          ackCallback:(AWSIoTMQTTAckBlock)ackCallBack {
    [self publishData:[str dataUsingEncoding:NSUTF8StringEncoding] onTopic:topic];
    
}

- (void)publishString:(NSString*)str onTopic:(NSString*)topic {
    [self publishData:[str dataUsingEncoding:NSUTF8StringEncoding] onTopic:topic];
}

- (void)publishString:(NSString*)str
                  qos:(UInt8)qos
              onTopic:(NSString*)topic
          ackCallback:(AWSIoTMQTTAckBlock)ackCallback {
    if (qos == 0 && ackCallback != nil) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Cannot specify `ackCallback` block for QoS = 0."];
    }
    [self publishData:[str dataUsingEncoding:NSUTF8StringEncoding]
                  qos:qos
              onTopic:topic
          ackCallback:ackCallback];
}

- (void)publishString:(NSString*)str qos:(UInt8)qos onTopic:(NSString*)topic {
    [self publishData:[str dataUsingEncoding:NSUTF8StringEncoding] qos:qos onTopic:topic];
}

- (void)publishData:(NSData*)data
            onTopic:(NSString*)topic {
    [self.session publishData:data onTopic:topic];
}

- (void)publishData:(NSData *)data
                qos:(UInt8)qos
            onTopic:(NSString *)topic {
    [self publishData:data
                  qos:qos
              onTopic:topic
          ackCallback:nil];
}

- (void)publishData:(NSData*)data
                qos:(UInt8)qos
            onTopic:(NSString*)topic
        ackCallback:(AWSIoTMQTTAckBlock)ackCallback {
    
    if (!_userDidIssueConnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call publish before connecting to the server"];
    }
    
    if (_userDidIssueDisconnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call publish after disconnecting from the server"];
    }
    
    if (qos > 1) {
        AWSDDLogError(@"invalid qos value: %u", qos);
        return;
    }
    if (qos == 0 && ackCallback != nil) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Cannot specify `ackCallback` block for QoS = 0."];
    }

    AWSDDLogVerbose(@"isReadyToPublish: %i", [self.session isReadyToPublish]);
    if (qos == 0) {
        [self.session publishData:data onTopic:topic];
    }
    else {
        UInt16 messageId = [self.session publishDataAtLeastOnce:data onTopic:topic];
        if (ackCallback) {
            [self.ackCallbackDictionary setObject:ackCallback
                                           forKey:[NSNumber numberWithInt:messageId]];
        }
    }
}

#pragma mark subscribe methods

- (void)subscribeToTopic:(NSString*)topic
                     qos:(UInt8)qos
         messageCallback:(AWSIoTMQTTNewMessageBlock)callback {
    [self subscribeToTopic:topic
                       qos:qos
           messageCallback:callback
               ackCallback:nil];
    
}

- (void)subscribeToTopic:(NSString*)topic
                     qos:(UInt8)qos
         messageCallback:(AWSIoTMQTTNewMessageBlock)callback
             ackCallback:(AWSIoTMQTTAckBlock)ackCallBack {
    if (!_userDidIssueConnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call subscribe before connecting to the server"];
    }
    
    if (_userDidIssueDisconnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call subscribe after disconnecting from the server"];
    }
    AWSDDLogInfo(@"(%@) Subscribing to topic %@ with messageCallback", self.clientId, topic);
    AWSIoTMQTTTopicModel *topicModel = [AWSIoTMQTTTopicModel new];
    topicModel.topic = topic;
    topicModel.qos = qos;
    topicModel.callback = callback;
    [self.topicListeners setObject:topicModel forKey:topic];
    
    UInt16 messageId = [self.session subscribeToTopic:topicModel.topic atLevel:topicModel.qos];
    AWSDDLogVerbose(@"(%@) Now subscribing w/ messageId: %d, qos: %u", self.clientId, messageId, qos);
    if (ackCallBack) {
        [self.ackCallbackDictionary setObject:ackCallBack
                                       forKey:[NSNumber numberWithInt:messageId]];
    }
}

- (void)subscribeToTopic:(NSString*)topic
                     qos:(UInt8)qos
        extendedCallback:(AWSIoTMQTTExtendedNewMessageBlock)callback {
    [self subscribeToTopic:topic
                       qos:qos
          extendedCallback:callback
               ackCallback:nil];
}

- (void)subscribeToTopic:(NSString*)topic
                     qos:(UInt8)qos
        extendedCallback:(AWSIoTMQTTExtendedNewMessageBlock)callback
             ackCallback:(AWSIoTMQTTAckBlock)ackCallback{
    if (!_userDidIssueConnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call subscribe before connecting to the server"];
    }
    
    if (_userDidIssueDisconnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call subscribe after disconnecting from the server"];
    }
    
    AWSDDLogInfo(@"(%@) Subscribing to topic %@ with ExtendedmessageCallback", self.clientId, topic);
    AWSIoTMQTTTopicModel *topicModel = [AWSIoTMQTTTopicModel new];
    topicModel.topic = topic;
    topicModel.qos = qos;
    topicModel.callback = nil;
    topicModel.extendedCallback = callback;
    [self.topicListeners setObject:topicModel forKey:topic];
    UInt16 messageId = [self.session subscribeToTopic:topicModel.topic atLevel:topicModel.qos];
    AWSDDLogVerbose(@"(%@) Now subscribing w/ messageId: %d, qos: %u", self.clientId, messageId, qos);
    if (ackCallback) {
        [self.ackCallbackDictionary setObject:ackCallback
                                       forKey:[NSNumber numberWithInt:messageId]];
    }
}

- (void)unsubscribeTopic:(NSString*)topic
             ackCallback:(AWSIoTMQTTAckBlock)ackCallback {
    if (!_userDidIssueConnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call unsubscribe before connecting to the server"];
    }
    
    if (_userDidIssueDisconnect) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Cannot call unsubscribe after disconnecting from the server"];
    }
    AWSDDLogInfo(@"(%@) Unsubscribing from topic %@", self.clientId, topic);
    UInt16 messageId = [self.session unsubscribeTopic:topic];
    [self.topicListeners removeObjectForKey:topic];
    if (ackCallback) {
        [self.ackCallbackDictionary setObject:ackCallback
                                       forKey:[NSNumber numberWithInt:messageId]];
    }
}

- (void)unsubscribeTopic:(NSString*)topic {
    [self unsubscribeTopic:topic ackCallback:nil];
}

#pragma-mark MQTTSessionDelegate

- (void)session:(AWSMQTTSession*)session handleEvent:(AWSMQTTSessionEvent)eventCode {
    AWSDDLogVerbose(@"(%@) MQTTSessionDelegate handleEvent: %i", self.clientId, eventCode);

    switch (eventCode) {
        case AWSMQTTSessionEventConnected:
            AWSDDLogInfo(@"(%@) MQTT session connected", self.clientId);
            self.mqttStatus = AWSIoTMQTTStatusConnected;
            [self notifyConnectionStatus];
          
            //Subscribe to prior topics
            if (_autoResubscribe) {
                AWSDDLogInfo(@"(%@) Auto-resubscribe is enabled. Resubscribing to topics.", self.clientId);
                for (AWSIoTMQTTTopicModel *topic in self.topicListeners.allValues) {
                    [self.session subscribeToTopic:topic.topic atLevel:topic.qos];
                }
            }
            break;
            
        case AWSMQTTSessionEventConnectionRefused:
            AWSDDLogWarn(@"(%@) MQTT session refused", self.clientId);
            self.mqttStatus = AWSIoTMQTTStatusConnectionRefused;
            [self notifyConnectionStatus];
            break;

        case AWSMQTTSessionEventConnectionClosed:
            AWSDDLogInfo(@"(%@) MQTTSessionEventConnectionClosed: MQTT session closed", self.clientId);
            
            //Check if user issued a disconnect
            if (self.userDidIssueDisconnect ) {
                //Clear all session state here.
                [self.topicListeners removeAllObjects];
                self.mqttStatus = AWSIoTMQTTStatusDisconnected;
                [self notifyConnectionStatus];
            }
            else {
                //Connection was closed unexpectedly.

                //Notify
                self.mqttStatus = AWSIoTMQTTStatusConnectionError;
                [self notifyConnectionStatus];

                //Clear all session state here as once disconnected, we do not retain any metadata.
                // This is done currently on `self.userDidIssueDisconnect`, but not when the error is from MQTT session error.
                [self.topicListeners removeAllObjects];
            }
            break;
        case AWSMQTTSessionEventConnectionError:
            AWSDDLogError(@"(%@) MQTTSessionEventConnectionError: Received an MQTT session connection error", self.clientId);
            
            if (self.userDidIssueDisconnect ) {
                //Clear all session state here.
                [self.topicListeners removeAllObjects];
                self.mqttStatus = AWSIoTMQTTStatusDisconnected;
                [self notifyConnectionStatus];
            }
            else {
                //Connection errored out unexpectedly.

                //Notify
                self.mqttStatus = AWSIoTMQTTStatusConnectionError;
                [self notifyConnectionStatus];

                // Clear all session state here as once errored out, we do not retain any metadata.
                // This is done currently on `self.userDidIssueDisconnect`, but not when the error is from MQTT session error.
                [self.topicListeners removeAllObjects];
            }
            break;
        case AWSMQTTSessionEventProtocolError:
            AWSDDLogError(@"(%@) MQTT session protocol error", self.clientId);
            self.mqttStatus = AWSIoTMQTTStatusProtocolError;
            [self notifyConnectionStatus];
            AWSDDLogError(@"(%@) Disconnecting", self.clientId);
            [self disconnect];
            break;
        default:
            break;
    }

}

#pragma mark subscription distributor

- (void)session:(AWSMQTTSession*)session newMessage:(NSData*)data onTopic:(NSString*)topic {
    AWSDDLogVerbose(@"(%@) MQTTSessionDelegate newMessage: %@ onTopic: %@", self.clientId, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], topic);

    NSArray *topicParts = [topic componentsSeparatedByString: @"/"];

    for (NSString *topicKey in self.topicListeners.allKeys) {
        NSArray *topicKeyParts = [topicKey componentsSeparatedByString: @"/"];

        BOOL topicMatch = true;
        for (int i = 0; i < topicKeyParts.count; i++) {
            if (i >= topicParts.count) {
                topicMatch = false;
                break;
            }

            NSString *topicPart = topicParts[i];
            NSString *topicKeyPart = topicKeyParts[i];

            if ([topicKeyPart rangeOfString:@"#"].location == NSNotFound && [topicKeyPart rangeOfString:@"+"].location == NSNotFound) {
                if (![topicPart isEqualToString:topicKeyPart]) {
                    topicMatch = false;
                    break;
                }
            }
        }

        if (topicMatch) {
            AWSDDLogVerbose(@"(%@) <<%@>>Topic: %@ is matched.", self.clientId, [NSThread currentThread], topic);
            AWSIoTMQTTTopicModel *topicModel = [self.topicListeners objectForKey:topicKey];
            if (topicModel) {
                if (topicModel.callback != nil) {
                    AWSDDLogVerbose(@"(%@) <<%@>>topicModel.callback.", self.clientId, [NSThread currentThread]);
                    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
                        topicModel.callback(data);
                    });
                }
                if (topicModel.extendedCallback != nil) {
                    AWSDDLogVerbose(@"(%@) <<%@>>topicModel.extendedcallback.", self.clientId, [NSThread currentThread]);
                    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
                        topicModel.extendedCallback(self, topic, data);
                    });
                }
                
                if (self.clientDelegate != nil ) {
                    AWSDDLogVerbose(@"(%@) <<%@>>Calling receivedMessageData on client Delegate.", self.clientId, [NSThread currentThread]);
                    dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
                        [self.clientDelegate receivedMessageData:data onTopic:topic];
                    });
                }
                
            }
        }
    }
}

#pragma mark callback handler

- (void)session:(AWSMQTTSession*)session newAckForMessageId:(UInt16)msgId {
    AWSDDLogVerbose(@"(%@) MQTTSessionDelegate new ack for msgId: %d", self.clientId, msgId);
    AWSIoTMQTTAckBlock callback = [[self ackCallbackDictionary] objectForKey:[NSNumber numberWithInt:msgId]];
    
    if (callback) {
        // Give callback to the client on a background thread
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void){
            callback();
        });
        [[self ackCallbackDictionary] removeObjectForKey:[NSNumber numberWithInt:msgId]];
    }
}

#pragma mark AWSSRWebSocketDelegate

- (void)webSocketDidOpen:(AWSSRWebSocket *)webSocket {
    AWSDDLogInfo(@"(%@) Websocket did open and is connected", self.clientId);

    // The WebSocket is connected; at this point we need to create streams
    // for MQTT encode/decode and then instantiate the MQTT client.
    NSInputStream *inputStreamRef;
    NSOutputStream *outputStreamRef;

    // 128KB is the maximum message size for AWS IoT
    // (see https://docs.aws.amazon.com/general/latest/gr/aws_service_limits.html).
    // The streams should be able to buffer an entire maximum-sized message
    // since the MQTT client isn't capable of dealing with partial reads.
    [NSStream getBoundStreamsWithBufferSize:128*1024
                                inputStream:&inputStreamRef
                               outputStream:&outputStreamRef];

    // This will be passed to the decoder as its input stream
    self.decoderStream = inputStreamRef;

    // This will be written to by webSocket:didReceiveMessage:
    self.toDecoderStream = outputStreamRef;
    [self.toDecoderStream setDelegate:self];

    // MQTT encoder writes to this one, which is bound at the other end to the WebSocket send method
    self.toWebSocketStream = [AWSIoTWebSocketOutputStreamFactory
                              createAWSIoTWebSocketOutputStreamWithWebSocket:webSocket];
    
    // Create Thread and start with "openStreams" being the entry point.
    if (self.streamsThread) {
        AWSDDLogVerbose(@"(%@) Issued Cancel on thread [%@]", self.clientId, self.streamsThread);
        [self.streamsThread cancel];
    }
    
    self.streamsThread = [[NSThread alloc] initWithTarget:self selector:@selector(openStreams:) object:nil];
    self.streamsThread.name = [NSString stringWithFormat:@"AWSIoTMQTTClient streamsThread %@", self.clientId];
    [self.streamsThread start];
}

- (void)webSocket:(AWSSRWebSocket *)webSocket didFailWithError:(NSError *)error;
{
    AWSDDLogError(@"(%@) WebsocketdidFailWithError:%@", self.clientId, error);

    // The WebSocket has failed.The input/output streams can be closed here.
    // Also, the webSocket can be set to nil
    [self.toDecoderStream close];
    [self.toWebSocketStream  close];
    [self.webSocket close];
    self.webSocket = nil;
    
    if (!self.userDidIssueDisconnect) {
        self.mqttStatus = AWSIoTMQTTStatusConnectionError;
        // Indicate an error to the connection status callback.
        [self notifyConnectionStatus];
    }
}

- (void)webSocket:(AWSSRWebSocket *)webSocket didReceiveMessage:(id)message;
{
    if ([message isKindOfClass:[NSData class]])
    {
        NSData *messageData = (NSData *)message;
        AWSDDLogVerbose(@"(%@) Websocket didReceiveMessage: Received %lu bytes", self.clientId, (unsigned long)messageData.length);
    
        // When a message is received, write it to the Decoder's input stream.
        [self.toDecoderStream write:[messageData bytes] maxLength:messageData.length];
    }
    else
    {
        AWSDDLogError(@"(%@) Websocket expected NSData object, but got a %@ object instead.", self.clientId, NSStringFromClass([message class]));
    }
}

- (void)webSocket:(AWSSRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean;
{
    AWSDDLogInfo(@"(%@) WebSocket closed with code:%ld with reason:%@", self.clientId, (long)code, reason);
    
    // The WebSocket has closed. The input/output streams can be closed here.
    // Also, the webSocket can be set to nil
    [self.toDecoderStream close];
    [self.toWebSocketStream  close];
    [self.webSocket close];
    self.webSocket = nil;
    
    // If this is not because of user initated disconnect, setup timer to retry.
    if (!self.userDidIssueDisconnect ) {
        self.mqttStatus = AWSIoTMQTTStatusConnectionError;
        // Indicate an error to the connection status callback.
        [self notifyConnectionStatus];
    }
}

- (void)webSocket:(AWSSRWebSocket *)webSocket didReceivePong:(NSData *)pongPayload;
{
    AWSDDLogVerbose(@"(%@) Websocket received pong", self.clientId);
}

@end
