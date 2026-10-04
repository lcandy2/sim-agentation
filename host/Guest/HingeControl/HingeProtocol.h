// Copied from baguette (https://github.com/tddworks/baguette, Injected/HingeControl
// at 5644ba2), Copyright 2026 tddworks, licensed under the Apache License 2.0
// (see host/Sources/SimBridge/LICENSE-baguette). Changes: the HID services'
// product names; the host builds it (see host/Sources/sim-agentation/Guest.swift).

#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

// Native enum values consumed by the simulator's orientation-picker-control.
static BOOL isHingeOrientation(NSString *value) {
  return [@[@"portrait", @"pud", @"landscape-left", @"landscape-right"] containsObject:value];
}

// Shared by one-shot and serving commands: usage error 2, dispatch error 1.
static int dispatchHingeOrientation(NSString *value, BOOL (^send)(const char *)) {
  if (!isHingeOrientation(value)) return 2;
  return send(value.UTF8String) ? 0 : 1;
}

// The host's side of a helper. `--deadline <unix-seconds>` precedes the verb:
// a helper not ready to act by then exits with this status and does nothing,
// so a host that stopped waiting knows a late start cannot move the device.
static const int HingeDeadlinePassedStatus = 3;

static BOOL parseHingeDeadline(const char *text, double *deadline) {
  char *end = NULL;
  double value = strtod(text, &end);
  if (end == text || *end != '\0' || !isfinite(value)) return NO;
  *deadline = value;
  return YES;
}

static BOOL hingeDeadlinePassed(double deadline) {
  return [NSDate date].timeIntervalSince1970 > deadline;
}

// Plays commands one per line until EOF. Each is answered with
// `done <status>` once played: 0 success, 1 dispatch failure, 2 invalid.
static void serveHingeCommands(FILE *input, FILE *output, int (^perform)(NSArray<NSString *> *)) {
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, input) > 0) {
    NSString *text = [[NSString stringWithUTF8String:line]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) continue;
    int status = perform([text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
    if (status) fprintf(stderr, "%s: %s\n", status == 2 ? "bad line" : "dispatch failed", text.UTF8String);
    fprintf(output, "done %d\n", status);
    fflush(output);
  }
  free(line);
}
