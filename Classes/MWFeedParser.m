//
//  MWFeedParser.m
//  MWFeedParser
//
//  Copyright (c) 2010 Michael Waterfall
//  
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//  
//  1. The above copyright notice and this permission notice shall be included
//     in all copies or substantial portions of the Software.
//  
//  2. This Software cannot be used to archive or collect data such as (but not
//     limited to) that of events, news, experiences and activities, for the 
//     purpose of any concept relating to diary/journal keeping.
//  
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "MWFeedParser.h"
#import "MWFeedParser_Private.h"
#import "NSString+HTML.h"
#import "NSDate+InternetDateTime.h"

// Implementation
@implementation MWFeedParser

// Properties
@synthesize url, delegate;
@synthesize urlConnection, asyncData, connectionType;
@synthesize feedParseType, item, info;
@synthesize stopped, parsing;
@synthesize tag;

#pragma mark -
#pragma mark NSObject

- (id)init
{
	if ((self = [super init]))
    {
		// Defaults
		feedParseType = ParseTypeFull;
		connectionType = ConnectionTypeSynchronously;
		
		// Date Formatters
		// Good info on internet dates here: http://developer.apple.com/iphone/library/qa/qa2010/qa1480.html
		NSLocale *en_US_POSIX = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
		dateFormatterRFC822 = [[NSDateFormatter alloc] init];
		dateFormatterRFC3339 = [[NSDateFormatter alloc] init];
        [dateFormatterRFC822 setLocale:en_US_POSIX];
        [dateFormatterRFC3339 setLocale:en_US_POSIX];
        [dateFormatterRFC822 setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
        [dateFormatterRFC3339 setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
		[en_US_POSIX release];
		
	}
	return self;
}

// Initialise with a URL
// Mainly for historic reasons before -parseURL:
- (id)initWithFeedURL:(NSURL *)feedURL
{
	if ((self = [self init]))
    {
		// Check if an string was passed as old init asked for NSString not NSURL
		if ([feedURL isKindOfClass:[NSString class]])
        {
			feedURL = [NSURL URLWithString:(NSString *)feedURL];
		}
		
		// Remember url
		self.url = feedURL;
	}
	return self;
}

- (void)dealloc
{
	[urlConnection release];
	[url release];
	[dateFormatterRFC822 release];
	[dateFormatterRFC3339 release];
	[item release];
	[info release];
	[super dealloc];
}

#pragma mark -
#pragma mark Parsing

// Reset data variables before processing
// Exclude parse state variables as they are needed after parse
- (void)reset
{
	self.asyncData = nil;
	self.urlConnection = nil;
	feedType = FeedTypeUnknown;
	self.item = nil;
	self.info = nil;
}

// Parse using URL for backwards compatibility
- (BOOL)parse
{
    
	// Reset
	[self reset];
	
	// Perform checks before parsing
	if (!url || !delegate)
    {
        [self parsingFailedWithErrorCode:MWErrorCodeNotInitiated 
                          andDescription:@"Delegate or URL not specified"];
        return NO;
    }
	if (parsing)
    {
        [self parsingFailedWithErrorCode:MWErrorCodeGeneral 
                          andDescription:@"Cannot start parsing as parsing is already in progress"];
        return NO;
    }
	
	// Reset state for next parse
	parsing = YES;
	stopped = NO;
	parsingComplete = NO;
	
	// Start
	BOOL success = YES;
	
	// Request
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
                                                                cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData 
                                                            timeoutInterval:60];
	[request setValue:@"MWFeedParser" forHTTPHeaderField:@"User-Agent"];
	
	// Debug Log
	MWLog(@"MWFeedParser: Connecting & downloading feed data");
	
	// Connection
	if (connectionType == ConnectionTypeAsynchronously)
    {
		// Async
		urlConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
		if (urlConnection)
        {
			asyncData = [[NSMutableData alloc] init];// Create data
		}
        else
        {
			[self parsingFailedWithErrorCode:MWErrorCodeConnectionFailed 
							  andDescription:[NSString stringWithFormat:@"Asynchronous connection failed to URL: %@", url]];
			success = NO;
		}
	}
    else
    {
		// Sync
		NSURLResponse *response = nil;
		NSError *error = nil;
		NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
		if (data && !error)
        {
			[self startParsingData:data]; // Process
		}
        else
        {
			[self parsingFailedWithErrorCode:MWErrorCodeConnectionFailed 
							  andDescription:[NSString stringWithFormat:@"Synchronous connection failed to URL: %@", url]];
			success = NO;
		}
	}
	
	// Cleanup & return
	[request release];
	return success;
	
}

// Begin XML parsing
- (void)startParsingData:(NSData *)data
{
	if (data)
    {
		// Create feed info
		MWFeedInfo *i = [[MWFeedInfo alloc] init];
		self.info = i;
		[i release];
		
        // Inform delegate
        if ([delegate respondsToSelector:@selector(feedParserDidStart:)])
            [delegate feedParserDidStart:self];
        
        // Parse items
        NSError *error = nil;
        GDataXMLDocument *xmlDoc = [[GDataXMLDocument alloc] initWithData:data 
                                                                  options:0 error:&error];
        if (xmlDoc)
        {
            error = nil;
            
            // Determine feed type
            if ([xmlDoc.rootElement.name compare:@"rss"] == NSOrderedSame)
            {
                feedType = FeedTypeRSS;
                if (feedParseType != ParseTypeItemsOnly)
                {
                    self.info.title = [[[xmlDoc.rootElement nodesForXPath:@"/rss/channel/title" error:&error] objectAtIndex:0] stringValue];
                    self.info.link = [[[xmlDoc.rootElement nodesForXPath:@"/rss/channel/link" error:&error] objectAtIndex:0] stringValue];
                    self.info.summary = [[[xmlDoc.rootElement nodesForXPath:@"/rss/channel/description" error:&error] objectAtIndex:0] stringValue];
                    
                    [self dispatchFeedInfoToDelegate];
                }
                
                if (feedParseType != ParseTypeInfoOnly)
                {
                    NSArray* items = [xmlDoc.rootElement nodesForXPath:@"channel/item" error:&error];
                    
                    for (GDataXMLElement* xmlItem in items)
                    {
                        // New item
                        MWFeedItem *newItem = [[MWFeedItem alloc] init];
                        self.item = newItem;
                        [newItem release];
                        
                        item.title = [[[xmlItem elementsForName:@"title"] objectAtIndex:0] stringValue];
                        item.link = [[[xmlItem elementsForName:@"link"] objectAtIndex:0] stringValue];
                        item.identifier = [[[xmlItem elementsForName:@"guid"] objectAtIndex:0] stringValue];
                        item.summary = [[[xmlItem elementsForName:@"description"] objectAtIndex:0] stringValue];
                        item.content = [[[xmlItem elementsForName:@"content:encoded"] objectAtIndex:0] stringValue];
                        
                        // Get date from possible fields
                        NSArray *dateArray = [xmlItem elementsForName:@"pubDate"];
                        if ([dateArray count] > 0)
                        {
                            item.date = [NSDate dateFromInternetDateTimeString:[[dateArray objectAtIndex:0] stringValue] formatHint:DateFormatHintRFC822];
                        }
                        else
                        {
                            dateArray = [xmlItem elementsForName:@"dc:date"];
                            if ([dateArray count] > 0)
                            {
                                item.date = [NSDate dateFromInternetDateTimeString:[[dateArray objectAtIndex:0] stringValue] formatHint:DateFormatHintRFC3339];
                            }
                        }
                        
                        // Handle enclosure
                        [self createEnclosureFromAttributes:[[xmlItem elementsForName:@"enclosure"] objectAtIndex:0] andAddToItem:item];
                        
                        [self dispatchFeedItemToDelegate];
                    }
                }
            }
            else if ([xmlDoc.rootElement.name compare:@"rdf:RDF"] == NSOrderedSame)
            {
                feedType = FeedTypeRSS1;
                if (feedParseType != ParseTypeItemsOnly)
                {
                    self.info.title = [[[xmlDoc.rootElement elementsForName:@"title"] objectAtIndex:0] stringValue];
                    self.info.link = [[[xmlDoc.rootElement elementsForName:@"link"] objectAtIndex:0] stringValue];
                    self.info.summary = [[[xmlDoc.rootElement elementsForName:@"description"] objectAtIndex:0] stringValue];
                    
                    [self dispatchFeedInfoToDelegate];
                }
                
                if (feedParseType != ParseTypeInfoOnly)
                {
                    NSArray* items = [xmlDoc.rootElement elementsForName:@"item"];
                    
                    for (GDataXMLElement* xmlItem in items)
                    {
                        // New item
                        MWFeedItem *newItem = [[MWFeedItem alloc] init];
                        self.item = newItem;
                        [newItem release];
                        
                        item.title = [[[xmlItem elementsForName:@"title"] objectAtIndex:0] stringValue];
                        item.link = [[[xmlItem elementsForName:@"link"] objectAtIndex:0] stringValue];
                        item.identifier = [[[xmlItem elementsForName:@"dc:identifier"] objectAtIndex:0] stringValue];
                        item.summary = [[[xmlItem elementsForName:@"description"] objectAtIndex:0] stringValue];
                        item.content = [[[xmlItem elementsForName:@"content:encoded"] objectAtIndex:0] stringValue];
                        item.date = [NSDate dateFromInternetDateTimeString:[[[xmlItem elementsForName:@"dc:date"] objectAtIndex:0] stringValue] formatHint:DateFormatHintRFC3339];
                        
                        // Handle enclosure
                        [self createEnclosureFromAttributes:[[xmlItem elementsForName:@"enc:enclosure"] objectAtIndex:0] andAddToItem:item];
                        
                        [self dispatchFeedItemToDelegate];
                    }
                }
            }
            else if ([xmlDoc.rootElement.name compare:@"feed"] == NSOrderedSame)
            {
                feedType = FeedTypeAtom;
                if (feedParseType != ParseTypeItemsOnly)
                {
                    self.info.title = [[[xmlDoc.rootElement elementsForName:@"title"] objectAtIndex:0] stringValue];
                    self.info.link = [[[xmlDoc.rootElement elementsForName:@"link"] objectAtIndex:0] stringValue];
                    self.info.summary = [[[xmlDoc.rootElement elementsForName:@"description"] objectAtIndex:0] stringValue];
                    
                    [self dispatchFeedInfoToDelegate];
                }
                
                if (feedParseType != ParseTypeInfoOnly)
                {
                    NSArray* items = [xmlDoc.rootElement elementsForName:@"entry"];
                    
                    for (GDataXMLElement* xmlItem in items)
                    {
                        // New item
                        MWFeedItem *newItem = [[MWFeedItem alloc] init];
                        self.item = newItem;
                        [newItem release];
                        
                        item.title = [[[xmlItem elementsForName:@"title"] objectAtIndex:0] stringValue];
                        [self processAtomLink:[[xmlItem elementsForName:@"link"] objectAtIndex:0] andAddToMWObject:item];
                        item.identifier = [[[xmlItem elementsForName:@"id"] objectAtIndex:0] stringValue];
                        item.summary = [[[xmlItem elementsForName:@"summary"] objectAtIndex:0] stringValue];
                        item.content = [[[xmlItem elementsForName:@"content"] objectAtIndex:0] stringValue];
                        item.date = [NSDate dateFromInternetDateTimeString:[[[xmlItem elementsForName:@"published"] objectAtIndex:0] stringValue] formatHint:DateFormatHintRFC3339];
                        item.updated = [NSDate dateFromInternetDateTimeString:[[[xmlItem elementsForName:@"updated"] objectAtIndex:0] stringValue] formatHint:DateFormatHintRFC3339];
                        
                        [self dispatchFeedItemToDelegate];
                    }
                }
            }
            else
            {
                [xmlDoc release];
                
                // Invalid format so fail
                [self parsingFailedWithErrorCode:MWErrorCodeFeedParsingError 
                                  andDescription:@"XML document is not a valid web feed document."];
                return;
            }
            
            [self parsingFinished];
		} else {
			[self parsingFailedWithErrorCode:MWErrorCodeFeedParsingError andDescription:@"Error with feed encoding"];
		}
        
        [xmlDoc release];
    }
}

// Stop parsing
- (void)stopParsing
{
	
	// Only if we're parsing
	if (parsing && !parsingComplete)
    {
		// Debug Log
		MWLog(@"MWFeedParser: Parsing stopped");
		
		// Stop
		stopped = YES;
		
		// Stop downloading
		[urlConnection cancel];
		self.urlConnection = nil;
		self.asyncData = nil;
		
		// Finished
		[self parsingFinished];
	}
	
}

// Finished parsing document successfully
- (void)parsingFinished
{
	// Finish
	if (!parsingComplete) {
		
		// Set state and notify delegate
		parsing = NO;
		parsingComplete = YES;
		if ([delegate respondsToSelector:@selector(feedParserDidFinish:)])
			[delegate feedParserDidFinish:self];
		
		// Reset
		[self reset];
	}
}

// If an error occurs, create NSError and inform delegate
- (void)parsingFailedWithErrorCode:(int)code andDescription:(NSString *)description
{
	// Finish & create error
	if (!parsingComplete)
    {
		// State
		parsing = NO;
		parsingComplete = YES;
		
		// Create error
		NSError *error = [NSError errorWithDomain:MWErrorDomain 
											 code:code 
										 userInfo:[NSDictionary dictionaryWithObject:description
																			  forKey:NSLocalizedDescriptionKey]];
		MWLog(@"%@", error);
		
		// Reset
		[self reset];
		
		// Inform delegate
		if ([delegate respondsToSelector:@selector(feedParser:didFailWithError:)])
			[delegate feedParser:self didFailWithError:error];
	}
}

#pragma mark -
#pragma mark NSURLConnection Delegate (Async)

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	[asyncData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	[asyncData appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	// Failed
	self.urlConnection = nil;
	self.asyncData = nil;
	
    // Error
	[self parsingFailedWithErrorCode:MWErrorCodeConnectionFailed andDescription:[error localizedDescription]];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	// Succeed
	MWLog(@"MWFeedParser: Connection successful... received %d bytes of data", [asyncData length]);
	
	// Parse
	if (!stopped) [self startParsingData:asyncData];
	
    // Cleanup
    self.urlConnection = nil;
    self.asyncData = nil;
}

-(NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
	return nil; // Don't cache
}

#pragma mark -
#pragma mark Send Items to Delegate

- (void)dispatchFeedInfoToDelegate
{
	if (info)
    {
		// Inform delegate
		if ([delegate respondsToSelector:@selector(feedParser:didParseFeedInfo:)])
			[delegate feedParser:self didParseFeedInfo:[[info retain] autorelease]];
		
		// Debug log
		MWLog(@"MWFeedParser: Feed info for \"%@\" successfully parsed", info.title);
		
		// Finish
		self.info = nil;
	}
}

- (void)dispatchFeedItemToDelegate
{
	if (item)
    {
		// Process before hand
		if (!item.summary) { item.summary = item.content; item.content = nil; }
		if (!item.date && item.updated) { item.date = item.updated; }
        
		// Debug log
		MWLog(@"MWFeedParser: Feed item \"%@\" successfully parsed", item.title);
		
		// Inform delegate
		if ([delegate respondsToSelector:@selector(feedParser:didParseFeedItem:)])
			[delegate feedParser:self didParseFeedItem:[[item retain] autorelease]];
		
		// Finish
		self.item = nil;
	}
}

#pragma mark -
#pragma mark Helpers & Properties

// Set URL to parse and removing feed: uri scheme info
// http://en.wikipedia.org/wiki/Feed:_URI_scheme
- (void)setUrl:(NSURL *)value
{
	// Check if an string was passed as old init asked for NSString not NSURL
	if ([value isKindOfClass:[NSString class]])
    {
		value = [NSURL URLWithString:(NSString *)value];
	}
	
	// Create new instance of NSURL and check URL scheme
	NSURL *newURL = nil;
	if (value)
    {
		if ([value.scheme isEqualToString:@"feed"])
        {
			// Remove feed URL scheme
			newURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",
                                           ([value.resourceSpecifier hasPrefix:@"//"] ? @"http:" : @""),
                                           value.resourceSpecifier]];
		}
        else
        {
			// Copy
			newURL = [[value copy] autorelease];
		}
	}
	
	// Set new url
	if (url) [url release];
	url = [newURL retain];
}

#pragma mark -
#pragma mark Misc

// Create an enclosure NSDictionary from enclosure (or link) attributes
- (BOOL)createEnclosureFromAttributes:(GDataXMLElement *)attributes andAddToItem:(MWFeedItem *)currentItem
{
	// Create enclosure
	NSDictionary *enclosure = nil;
	NSString *encURL = nil, *encType = nil;
	NSNumber *encLength = nil;
	if (attributes) {
		switch (feedType) {
			case FeedTypeRSS: // http://cyber.law.harvard.edu/rss/rss.html#ltenclosuregtSubelementOfLtitemgt
            {
				// <enclosure>
                encURL = [[attributes attributeForName:@"url"] stringValue];
				encType = [[attributes attributeForName:@"type"] stringValue];
				encLength = [NSNumber numberWithLongLong:[[[attributes attributeForName:@"length"] stringValue] longLongValue]];
				break;
			}
			case FeedTypeRSS1: // http://www.xs4all.nl/~foz/mod_enclosure.html
            {
				// <enc:enclosure>
                encURL = [[attributes attributeForName:@"rdf:resource"] stringValue];
				encType = [[attributes attributeForName:@"enc:type"] stringValue];
				encLength = [NSNumber numberWithLongLong:[[[attributes attributeForName:@"enc:length"] stringValue] longLongValue]];
				break;
			}
			case FeedTypeAtom: // http://www.atomenabled.org/developers/syndication/atom-format-spec.php#rel_attribute
            {
				// <link rel="enclosure" href=...
				if ([[[attributes attributeForName:@"rel"] stringValue] isEqualToString:@"enclosure"])
                {
                    encURL = [[attributes attributeForName:@"href"] stringValue];
                    encType = [[attributes attributeForName:@"type"] stringValue];
                    encLength = [NSNumber numberWithLongLong:[[[attributes attributeForName:@"length"] stringValue] longLongValue]];
				}
				break;
			}
			default:
                break;
		}
	}
    
	if (encURL)
    {
		NSMutableDictionary *e = [[NSMutableDictionary alloc] initWithCapacity:3];
		[e setObject:encURL forKey:@"url"];
		if (encType) [e setObject:encType forKey:@"type"];
		if (encLength) [e setObject:encLength forKey:@"length"];
		enclosure = [NSDictionary dictionaryWithDictionary:e];
		[e release];
	}
    
	// Add to item		 
	if (enclosure)
    {
		if (currentItem.enclosures)
        {
			currentItem.enclosures = [currentItem.enclosures arrayByAddingObject:enclosure];
		}
        else
        {
			currentItem.enclosures = [NSArray arrayWithObject:enclosure];
		}
		return YES;
	}
    else
    {
		return NO;
	}
}

// Process ATOM link and determine whether to ignore it, add it as the link element or add as enclosure
// Links can be added to MWObject (info or item)
- (BOOL)processAtomLink:(GDataXMLElement *)attributes andAddToMWObject:(id)MWObject
{
	if (attributes && [attributes attributeForName:@"rel"])
    {
		// Use as link if rel == alternate
		if ([[[attributes attributeForName:@"rel"] stringValue] isEqualToString:@"alternate"])
        {
			[MWObject setLink:[[attributes attributeForName:@"href"] stringValue]]; // Can be added to MWFeedItem or MWFeedInfo
			return YES;
		}
		
		// Use as enclosure if rel == enclosure
		if ([[[attributes attributeForName:@"rel"] stringValue] isEqualToString:@"enclosure"])
        {
			if ([MWObject isMemberOfClass:[MWFeedItem class]]) // Enclosures can only be added to MWFeedItem
            {
				[self createEnclosureFromAttributes:attributes andAddToItem:(MWFeedItem *)MWObject];
				return YES;
			}
		}
	}
	return NO;
}

@end