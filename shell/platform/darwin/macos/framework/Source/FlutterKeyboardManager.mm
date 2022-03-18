// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterKeyboardManager.h"

#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterChannelKeyResponder.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterEmbedderKeyResponder.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterEngine_Internal.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterKeyPrimaryResponder.h"

namespace {
typedef void (^VoidBlock)();
}

@interface FlutterKeyboardManager ()

/**
 * The text input plugin set by initialization.
 */
@property(nonatomic) id<FlutterKeyboardViewDelegate> viewDelegate;

/**
 * The primary responders added by addPrimaryResponder.
 */
@property(nonatomic) NSMutableArray<id<FlutterKeyPrimaryResponder>>* primaryResponders;

@property(nonatomic) NSMutableArray<NSEvent*>* pendingTextEvents;

@property(nonatomic) BOOL processingEvent;

/**
 * Add a primary responder, which asynchronously decides whether to handle an
 * event.
 */
- (void)addPrimaryResponder:(nonnull id<FlutterKeyPrimaryResponder>)responder;

- (void)processNextEvent;

- (void)processEvent:(NSEvent*)event onFinish:(VoidBlock)onFinish;

- (void)dispatchTextEvent:(NSEvent*)pendingEvent;

@end

@implementation FlutterKeyboardManager {
  NextResponderProvider _getNextResponder;
}

- (nonnull instancetype)initWithViewDelegate:(nonnull id<FlutterKeyboardViewDelegate>)viewDelegate {
  self = [super init];
  if (self != nil) {
    _processingEvent = FALSE;
    _viewDelegate = viewDelegate;

    _primaryResponders = [[NSMutableArray alloc] init];
    [self addPrimaryResponder:[[FlutterEmbedderKeyResponder alloc]
                                  initWithSendEvent:^(const FlutterKeyEvent& event,
                                                      FlutterKeyEventCallback callback,
                                                      void* userData) {
                                    [_viewDelegate sendKeyEvent:event
                                                       callback:callback
                                                       userData:userData];
                                  }]];
    [self
        addPrimaryResponder:[[FlutterChannelKeyResponder alloc]
                                initWithChannel:[FlutterBasicMessageChannel
                                                    messageChannelWithName:@"flutter/keyevent"
                                                           binaryMessenger:[_viewDelegate
                                                                               getBinaryMessenger]
                                                                     codec:[FlutterJSONMessageCodec
                                                                               sharedInstance]]]];
    _pendingTextEvents = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)addPrimaryResponder:(nonnull id<FlutterKeyPrimaryResponder>)responder {
  [_primaryResponders addObject:responder];
}

- (void)handleEvent:(nonnull NSEvent*)event {
  // Be sure to add a handling method in propagateKeyEvent when allowing more
  // event types here.
  if (event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp &&
      event.type != NSEventTypeFlagsChanged) {
    return;
  }

  [_pendingTextEvents addObject:event];
  [self processNextEvent];
}

#pragma mark - Private

- (void)processNextEvent {
  if (_processingEvent || [_pendingTextEvents count] == 0) {
    return;
  }
  _processingEvent = TRUE;

  NSEvent* pendingEvent = [_pendingTextEvents firstObject];
  [_pendingTextEvents removeObjectAtIndex:0];
  // NSLog(@"Dispatching, remaining %lu", [_pendingTextEvents count]);

  __weak __typeof__(self) weakSelf = self;
  VoidBlock onFinish = ^() {
    weakSelf.processingEvent = FALSE;
    [weakSelf processNextEvent];
  };
  [self processEvent:pendingEvent onFinish:onFinish];
}

- (void)processEvent:(NSEvent*)event onFinish:(VoidBlock)onFinish {
  if (_viewDelegate.isComposing) {
    [self dispatchTextEvent:event];
    onFinish();
    return;
  }

  // Having no primary responders require extra logic, but Flutter hard-codes
  // all primary responders, so this is a situation that Flutter will never
  // encounter.
  NSAssert([_primaryResponders count] >= 0, @"At least one primary responder must be added.");

  __weak __typeof__(self) weakSelf = self;
  __block int unreplied = [_primaryResponders count];
  __block BOOL anyHandled = false;

  FlutterAsyncKeyCallback replyCallback = ^(BOOL handled) {
    unreplied -= 1;
    NSAssert(unreplied >= 0, @"More primary responders replied than possible.");
    anyHandled = anyHandled || handled;
    if (unreplied == 0) {
      if (!anyHandled) {
        [weakSelf dispatchTextEvent:event];
      }
      onFinish();
    }
  };

  for (id<FlutterKeyPrimaryResponder> responder in _primaryResponders) {
    [responder handleEvent:event callback:replyCallback];
  }
}

- (void)dispatchTextEvent:(NSEvent*)event {
  if ([_viewDelegate onTextInputKeyEvent:event]) {
    return;
  }
  NSResponder* nextResponder = _viewDelegate.nextResponder;
  if (nextResponder == nil) {
    return;
  }
  NSLog(@"Sending to system: [%lu] 0x%x", event.type, event.keyCode);
  switch (event.type) {
    case NSEventTypeKeyDown:
      if ([nextResponder respondsToSelector:@selector(keyDown:)]) {
        [nextResponder keyDown:event];
      }
      break;
    case NSEventTypeKeyUp:
      if ([nextResponder respondsToSelector:@selector(keyUp:)]) {
        [nextResponder keyUp:event];
      }
      break;
    case NSEventTypeFlagsChanged:
      if ([nextResponder respondsToSelector:@selector(flagsChanged:)]) {
        [nextResponder flagsChanged:event];
      }
      break;
    default:
      NSAssert(false, @"Unexpected key event type (got %lu).", event.type);
  }
}

@end
