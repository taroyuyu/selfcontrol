//
//  BlockManager.m
//  SelfControl
//
//  Created by Charles Stigler on 2/5/13.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "BlockManager.h"
#import "AllowlistScraper.h"
#import "SCBlockEntry.h"

@implementation BlockManager

BOOL appendMode = NO;

- (BlockManager*)init {
	return [self initAsAllowlist: NO allowLocal: YES includeCommonSubdomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist {
	return [self initAsAllowlist: allowlist allowLocal: YES includeCommonSubdomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local {
	return [self initAsAllowlist: allowlist allowLocal: local includeCommonSubdomains: YES];
}
- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon {
	return [self initAsAllowlist: allowlist allowLocal: local includeCommonSubdomains: blockCommon includeLinkedDomains: YES];
}

- (BlockManager*)initAsAllowlist:(BOOL)allowlist allowLocal:(BOOL)local includeCommonSubdomains:(BOOL)blockCommon includeLinkedDomains:(BOOL)includeLinked {
	if(self = [super init]) {
		opQueue = [[NSOperationQueue alloc] init];
		[opQueue setMaxConcurrentOperationCount: 20];

		pf = [[PacketFilter alloc] initAsAllowlist: allowlist];
		hostsBlocker = [[HostFileBlocker alloc] init];
		hostsBlockingEnabled = NO;

		isAllowlist = allowlist;
		allowLocal = local;
		includeCommonSubdomains = blockCommon;
		includeLinkedDomains = includeLinked;
	}

	return self;
}

- (void)prepareToAddBlock {
	if([hostsBlocker containsSelfControlBlock]) {
		[hostsBlocker removeSelfControlBlock];
		[hostsBlocker writeNewFileContents];
	}

	if(!isAllowlist && ![hostsBlocker containsSelfControlBlock] && [hostsBlocker createBackupHostsFile]) {
		[hostsBlocker addSelfControlBlockHeader];
		hostsBlockingEnabled = YES;
	} else {
		hostsBlockingEnabled = NO;
	}
}

- (void)enterAppendMode {
    if (isAllowlist) {
        NSLog(@"ERROR: can't append to allowlist block");
        return;
    }
    if(![hostsBlocker containsSelfControlBlock]) {
        NSLog(@"ERROR: can't append to hosts block that doesn't yet exist");
        return;
    }
    
    hostsBlockingEnabled = YES;
    appendMode = YES;
    [pf enterAppendMode];
}
- (void)finishAppending {
    NSLog(@"About to run operation queue for appending...");
    [opQueue waitUntilAllOperationsAreFinished];
    NSLog(@"Operation queue ran!");

    [hostsBlocker writeNewFileContents];
    [pf finishAppending];
    [pf refreshPFRules];
    appendMode = NO;
}

- (void)finalizeBlock {
    NSLog(@"About to run operation queue...");
	[opQueue waitUntilAllOperationsAreFinished];
    NSLog(@"Operation queue ran!");

	if(hostsBlockingEnabled) {
		[hostsBlocker addSelfControlBlockFooter];
		[hostsBlocker writeNewFileContents];
	}

	[pf startBlock];
}

- (void)enqueueBlockEntry:(SCBlockEntry*)entry {
    NSLog(@"enqueue entry %@", entry);
	NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
        [self addBlockEntry: entry];
	}];
	[opQueue addOperation: op];
}

- (void)addBlockEntry:(SCBlockEntry*)entry {
    // nil entries = something didn't parse right
    if (entry == nil) return;

	BOOL isIP = [entry.hostname isValidIPAddress];
	BOOL isIPv4 = [entry.hostname isValidIPv4Address];

	if([entry.hostname isEqualToString: @"*"]) {
		[pf addRuleWithIP: nil port: entry.port maskLen: 0];
	} else if(isIPv4) { // current we do NOT do ipfw blocking for IPv6
		[pf addRuleWithIP: entry.hostname port: entry.port maskLen: entry.maskLen];
	} else if(!isIP && (![self domainIsGoogle: entry.hostname] || isAllowlist)) { // domain name
		// on blocklist blocks where the domain is Google, we don't use ipfw to block
		// because we'd end up blocking more than the user wants (i.e. Search/Reader)
		NSArray* addresses = [self ipAddressesForDomainName: entry.hostname];

		for(NSUInteger i = 0; i < [addresses count]; i++) {
			NSString* ip = addresses[i];

			[pf addRuleWithIP: ip port: entry.port maskLen: entry.maskLen];
		}
	}

	if(hostsBlockingEnabled && ![entry.hostname isEqualToString: @"*"] && !entry.port && !isIP) {
        if (appendMode) {
            [hostsBlocker appendExistingBlockWithRuleForDomain: entry.hostname];
        } else {
            [hostsBlocker addRuleBlockingDomain: entry.hostname];
        }
	}
}

- (void)addBlockEntryFromString:(NSString*)entryString {
    NSLog(@"adding block entry from string: %@", entryString);
    SCBlockEntry* entry = [SCBlockEntry entryFromString: entryString];

    // nil means that we don't have anything valid to block in this entry
    if (entry == nil) return;

    [self addBlockEntry: entry];
    
    NSArray<SCBlockEntry*>* relatedEntries = [self relatedBlockEntriesForEntry: entry];
    NSLog(@"Enqueuing related entries to %@: %@", entry, relatedEntries);
    for (SCBlockEntry* relatedEntry in relatedEntries) {
        [self enqueueBlockEntry: relatedEntry];
    }
}

- (void)addBlockEntriesFromStrings:(NSArray<NSString*>*)blockList {
	for(NSUInteger i = 0; i < [blockList count]; i++) {
		NSBlockOperation* op = [NSBlockOperation blockOperationWithBlock:^{
			[self addBlockEntryFromString: blockList[i]];
		}];
		[opQueue addOperation: op];
	}
}

- (BOOL)clearBlock {
	[pf stopBlock: false];
	BOOL pfSuccess = ![pf containsSelfControlBlock];

	[hostsBlocker removeSelfControlBlock];
	BOOL hostSuccess = [hostsBlocker writeNewFileContents];
	// Revert the host file blocker's file contents to disk so we can check
	// whether or not it still contains the block (aka we messed up).
	[hostsBlocker revertFileContentsToDisk];
	hostSuccess = hostSuccess && ![hostsBlocker containsSelfControlBlock];

	BOOL clearedSuccessfully = hostSuccess && pfSuccess;

	if(clearedSuccessfully)
		NSLog(@"INFO: Block successfully cleared.");
	else {
		if (!pfSuccess) {
			NSLog(@"WARNING: Error clearing pf block. Tring to clear using force.");
			[pf stopBlock: true];
		}
		if (!hostSuccess) {
			NSLog(@"WARNING: Error removing hostfile block.  Attempting to restore host file backup.");
			[hostsBlocker restoreBackupHostsFile];
		}

		clearedSuccessfully = ![self blockIsActive];

		if ([hostsBlocker containsSelfControlBlock]) {
			NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
		}
		if ([pf containsSelfControlBlock]) {
			NSLog(@"ERROR: Firewall rules could not be cleared.  This may result in a permanent block.");
		}
		if (clearedSuccessfully) {
			NSLog(@"INFO: Firewall rules successfully cleared.");
		}
	}

	[hostsBlocker deleteBackupHostsFile];

	return clearedSuccessfully;
}

- (BOOL)forceClearBlock {
	[pf stopBlock: YES];
	BOOL pfSuccess = ![pf containsSelfControlBlock];

	[hostsBlocker removeSelfControlBlock];
	BOOL hostSuccess = [hostsBlocker writeNewFileContents];
	// Revert the host file blocker's file contents to disk so we can check
	// whether or not it still contains the block (aka we messed up).
	[hostsBlocker revertFileContentsToDisk];
	hostSuccess = hostSuccess && ![hostsBlocker containsSelfControlBlock];

	BOOL clearedSuccessfully = hostSuccess && pfSuccess;

	if(clearedSuccessfully)
		NSLog(@"INFO: Block successfully cleared.");
	else {
		if (!pfSuccess) {
			NSLog(@"ERROR: Error clearing pf block. This may result in a permanent block.");
		}
		if (!hostSuccess) {
			NSLog(@"WARNING: Error removing hostfile block.  Attempting to restore host file backup.");
			[hostsBlocker restoreBackupHostsFile];
		}

		clearedSuccessfully = ![self blockIsActive];

		if ([hostsBlocker containsSelfControlBlock]) {
			NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
		}
		if (clearedSuccessfully) {
			NSLog(@"INFO: Firewall rules successfully cleared.");
		}
	}

	return clearedSuccessfully;
}

- (BOOL)blockIsActive {
	return [hostsBlocker containsSelfControlBlock] || [pf containsSelfControlBlock];
}

- (NSArray*)commonSubdomainsForHostName:(NSString*)hostName {
	NSMutableSet* newHosts = [NSMutableSet set];

	// If the domain ends in facebook.com...  Special case for Facebook because
	// users will often forget to block some of its many mirror subdomains that resolve
	// to different IPs, i.e. hs.facebook.com.  Thanks to Danielle for raising this issue.
	if([hostName hasSuffix: @"facebook.com"]) {
		// pulled list of facebook IP ranges from https://developers.facebook.com/docs/sharing/webmasters/crawler
		// TODO: pull these automatically by running:
		// whois -h whois.radb.net -- '-i origin AS32934' | grep ^route
        // (looks like they now use 2 different AS numbers: https://www.facebook.com/peering/)
		NSArray* facebookIPs = @[@"31.13.24.0/21",
                                 @"31.13.64.0/18",
                                 @"45.64.40.0/22",
                                 @"66.220.144.0/20",
                                 @"69.63.176.0/20",
                                 @"69.171.224.0/19",
                                 @"74.119.76.0/22",
                                 @"102.132.96.0/20",
                                 @"103.4.96.0/22",
                                 @"129.134.0.0/16",
                                 @"147.75.208.0/20",
                                 @"157.240.0.0/16",
                                 @"173.252.64.0/18",
                                 @"179.60.192.0/22",
                                 @"185.60.216.0/22",
                                 @"185.89.216.0/22",
                                 @"199.201.64.0/22",
                                 @"204.15.20.0/22"];

		[newHosts addObjectsFromArray: facebookIPs];
	}
	if ([hostName hasSuffix: @"twitter.com"]) {
		[newHosts addObject: @"api.twitter.com"];
	}

	// Block the domain with no subdomains, if www.domain is blocked
	if([hostName rangeOfString: @"www."].location == 0) {
		[newHosts addObject: [hostName substringFromIndex: 4]];
	} else { // Or block www.domain otherwise
		[newHosts addObject: [@"www." stringByAppendingString: hostName]];
	}

	return [newHosts allObjects];
}

- (NSArray*)ipAddressesForDomainName:(NSString*)domainName {
	NSHost* host = [NSHost hostWithName: domainName];

	if(!host) {
		return @[];
	}

	NSDate* startedResolving = [NSDate date];
	NSArray* addresses = [host addresses];

	// log slow resolutions
	// TODO: present this back to the user somehow, even help them remove slow-resolving hosts?
	NSDate* finishedResolving  = [NSDate date];
	NSTimeInterval resolutionTime = [finishedResolving timeIntervalSinceDate: startedResolving];
	if (resolutionTime > 2.5) {
		NSLog(@"Warning: took %f seconds to resolve %@", resolutionTime, host.name);
	}

	return addresses;
}

- (BOOL)domainIsGoogle:(NSString*)domainName {
	// todo: make this regex not suck
	NSString* googleRegex = @"^([a-z0-9]+\\.)*(google|youtube|picasa|sketchup|blogger|blogspot)\\.([a-z]{1,3})(\\.[a-z]{1,3})?$";
	NSPredicate* googleTester = [NSPredicate
								 predicateWithFormat: @"SELF MATCHES %@",
								 googleRegex
								 ];
	return [googleTester evaluateWithObject: domainName];
}

- (NSArray<SCBlockEntry*>*)relatedBlockEntriesForEntry:(SCBlockEntry*)entry {
    // nil means that we don't have anything valid to block in this entry, therefore no related entries either
    if (entry == nil) return @[];
    
    NSMutableArray<SCBlockEntry*>* relatedEntries = [NSMutableArray array];

    if (isAllowlist && includeLinkedDomains && ![entry.hostname isValidIPAddress]) {
        NSArray<SCBlockEntry*>* scrapedEntries = [[AllowlistScraper relatedBlockEntries: entry.hostname] allObjects];
        [relatedEntries addObjectsFromArray: scrapedEntries];
    }

    if(![entry.hostname isValidIPAddress] && includeCommonSubdomains) {
        NSArray<NSString*>* commonSubdomains = [self commonSubdomainsForHostName: entry.hostname];

        for (NSString* subdomain in commonSubdomains) {
            // we do not pull port, we leave the port number the same as we got it
            SCBlockEntry* subdomainEntry = [SCBlockEntry entryFromString: subdomain];

            if (subdomainEntry == nil) continue;
            
            [relatedEntries addObject: subdomainEntry];
        }
    }
    
    return relatedEntries;
}

@end
