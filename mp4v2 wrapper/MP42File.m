//
//  MP42File.m
//  Subler
//
//  Created by Damiano Galassi on 31/01/09.
//  Copyright 2009 Damiano Galassi. All rights reserved.
//

#import "MP42File.h"
#import <QTKit/QTKit.h>
#import "SubUtilities.h"
#import "SBLanguages.h"

#if __MAC_OS_X_VERSION_MAX_ALLOWED > 1060
#import <AVFoundation/AVFoundation.h>
#endif

#import "MP42FileImporter.h"

NSString * const MP42Create64BitData = @"64BitData";
NSString * const MP42Create64BitTime = @"64BitTime";
NSString * const MP42CreateChaptersPreviewTrack = @"ChaptersPreview";

NSString * const MP42FileTypeMP4 = @"mp4";
NSString * const MP42FileTypeM4V = @"m4v";
NSString * const MP42FileTypeM4A = @"m4a";
NSString * const MP42FileTypeM4B = @"m4b";

@interface MP42File (Private)

- (void) removeMuxedTrack: (MP42Track *)track;
- (BOOL) createChaptersPreview;

@end

@implementation MP42File

- (id)init
{
    if ((self = [super init])) {
        hasFileRepresentation = NO;
        tracks = [[NSMutableArray alloc] init];
        tracksToBeDeleted = [[NSMutableArray alloc] init];

        metadata = [[MP42Metadata alloc] init];
        fileImporters = [[NSMutableArray alloc] init];
    }
    return self;
}

- (id)initWithDelegate:(id)del;
{
    if ((self = [self init])) {
        delegate = del;
    }

    return self;
}

- (id)initWithExistingFile:(NSURL *)URL andDelegate:(id)del;
{
    if ((self = [super init]))
	{
        delegate = del;
		fileHandle = MP4Read([[URL path] UTF8String]);

        if (!fileHandle) {
            [self release];
			return nil;
        }

        const char* brand = NULL;
        MP4GetStringProperty(fileHandle, "ftyp.majorBrand", &brand);
        if (brand != NULL) {
            if (!strcmp(brand, "qt  ")) {
                MP4Close(fileHandle, 0);
                [self release];
                return nil;
            }
        }

        fileURL = [URL retain];
        hasFileRepresentation = YES;

        tracks = [[NSMutableArray alloc] init];
        int i, tracksCount = MP4GetNumberOfTracks(fileHandle, 0, 0);
        MP4TrackId chapterId = findChapterTrackId(fileHandle);

        for (i=0; i< tracksCount; i++) {
            id track;
            MP4TrackId trackId = MP4FindTrackId(fileHandle, i, 0, 0);
            const char* type = MP4GetTrackType(fileHandle, trackId);

            if (MP4_IS_AUDIO_TRACK_TYPE(type))
                track = [MP42AudioTrack alloc];
            else if (MP4_IS_VIDEO_TRACK_TYPE(type))
                track = [MP42VideoTrack alloc];
            else if (!strcmp(type, MP4_TEXT_TRACK_TYPE)) {
                if (trackId == chapterId)
                    track = [MP42ChapterTrack alloc];
                else
                    track = [MP42Track alloc];
            }
            else if (!strcmp(type, MP4_SUBTITLE_TRACK_TYPE))
                track = [MP42SubtitleTrack alloc];
            else if (!strcmp(type, MP4_SUBPIC_TRACK_TYPE))
                track = [MP42SubtitleTrack alloc];
            else if (!strcmp(type, MP4_CC_TRACK_TYPE))
                track = [MP42ClosedCaptionTrack alloc];
            else
                track = [MP42Track alloc];

            track = [track initWithSourceURL:fileURL trackID:trackId fileHandle:fileHandle];
            [tracks addObject:track];
            [track release];
        }

        tracksToBeDeleted = [[NSMutableArray alloc] init];
        metadata = [[MP42Metadata alloc] initWithSourceURL:fileURL fileHandle:fileHandle];
        fileImporters = [[NSMutableArray alloc] init];
        MP4Close(fileHandle, 0);

        _size = [[[[NSFileManager defaultManager] attributesOfItemAtPath:[fileURL path] error:nil] valueForKey:NSFileSize] unsignedLongLongValue];
	}

	return self;
}

- (NSUInteger) movieDuration
{
    NSUInteger duration = 0;
    NSUInteger trackDuration = 0;
    for (MP42Track *track in tracks)
        if ((trackDuration = [track duration]) > duration)
            duration = trackDuration;
    
    return duration;
}

- (MP42ChapterTrack*) chapters
{
    MP42ChapterTrack * chapterTrack = nil;

    for (MP42Track * track in tracks)
        if ([track isMemberOfClass:[MP42ChapterTrack class]])
            chapterTrack = (MP42ChapterTrack*) track;

    return [[chapterTrack retain] autorelease];
}

- (void)removeTracksAtIndexes:(NSIndexSet *)indexes
{
    NSUInteger index = [indexes firstIndex];
    while (index != NSNotFound) {    
        MP42Track *track = [tracks objectAtIndex:index];
        if (track.muxed)
            [tracksToBeDeleted addObject:track];    
        index = [indexes indexGreaterThanIndex:index];
    }

    [tracks removeObjectsAtIndexes:indexes]; 
}

- (NSUInteger)tracksCount
{
    return [tracks count];
}

- (id)trackAtIndex:(NSUInteger) index
{
    return [tracks objectAtIndex:index];
}

- (void)addTrack:(id) object
{
    MP42Track *track = (MP42Track *) object;
    track.sourceId = track.Id;
    track.Id = 0;
    track.muxed = NO;
    track.isEdited = YES;

    track.language = track.language;
    track.name = track.name;
    if ([track isMemberOfClass:[MP42ChapterTrack class]]) {
        for (id previousTrack in tracks)
            if ([previousTrack isMemberOfClass:[MP42ChapterTrack class]]) {
                [tracks removeObject:previousTrack];
                break;
        }
    }

    if (trackNeedConversion(track.format))
        track.needConversion = YES;

    if (track.trackImporterHelper)
        [fileImporters addObject:track.trackImporterHelper];

    [tracks addObject:track];
}

- (void)removeTrackAtIndex:(NSUInteger) index
{
    MP42Track *track = [tracks objectAtIndex:index];
    if (track.muxed)
        [tracksToBeDeleted addObject:track];
    [tracks removeObjectAtIndex:index];
}

- (void) moveTrackAtIndex: (NSUInteger)index toIndex:(NSUInteger) newIndex
{
    id track = [[tracks objectAtIndex:index] retain];

    [tracks removeObjectAtIndex:index];
    if (newIndex > [tracks count] || newIndex > index)
        newIndex--;
    [tracks insertObject:track atIndex:newIndex];
    [track release];
}

- (BOOL) optimize
{
    __block BOOL noErr = NO;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error;
    NSURL *folderURL = [fileURL URLByDeletingLastPathComponent];

    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSURL *tempURL = [fileManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:folderURL create:YES error:&error];

    if (tempURL) {
        tempURL = [tempURL URLByAppendingPathComponent:[fileURL lastPathComponent]];

        unsigned long long originalFileSize = [[[fileManager attributesOfItemAtPath:[fileURL path] error:nil] valueForKey:NSFileSize] unsignedLongLongValue];

        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            noErr = MP4Optimize([[fileURL path] UTF8String], [[tempURL path] UTF8String]);
        });

        while (!noErr) {
            unsigned long long fileSize = [[[fileManager attributesOfItemAtPath:[tempURL path] error:nil] valueForKey:NSFileSize] unsignedLongLongValue];
            [self progressStatus:((CGFloat)fileSize / originalFileSize) * 100];
            usleep(450000);
        }

        if (noErr) {
            NSURL *result = nil;
            noErr = [fileManager replaceItemAtURL:fileURL withItemAtURL:tempURL backupItemName:nil options:0 resultingItemURL:&result error:&error];
            if (noErr) {
                [fileURL release];
                fileURL = [result retain];
            }
        }
    }

    [fileManager release];
    [pool release];

    return noErr;
}

- (BOOL) writeToUrl:(NSURL *)url withAttributes:(NSDictionary *)attributes error:(NSError **)outError
{
    BOOL success = YES;
    
    if(!url) {
        if (outError)
            *outError = MP42Error(@"Invalid path.", @"The destination path cannot be empty.", 100);

        return NO;
    }
    
    if ([self hasFileRepresentation]) {
        if (![fileURL isEqualTo:url]) {
            __block BOOL done = NO;
            NSFileManager *fileManager = [[NSFileManager alloc] init];
            unsigned long long originalFileSize = [[[fileManager attributesOfItemAtPath:[fileURL path] error:outError] valueForKey:NSFileSize] unsignedLongLongValue];

            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                done = [fileManager copyItemAtURL:fileURL toURL:url error:outError];
            });

            while (!done) {
                unsigned long long fileSize = [[[fileManager attributesOfItemAtPath:[url path] error:outError] valueForKey:NSFileSize] unsignedLongLongValue];
                [self progressStatus:((CGFloat)fileSize / originalFileSize) * 100];
                usleep(450000);
            }
            [fileManager release];
        }

        fileURL = [url retain];
        success = [self updateMP4FileWithAttributes:attributes error:outError];
    }
    else {
        fileURL = [url retain];

        NSString *fileExtension = [fileURL pathExtension];
        char* majorBrand = "mp42";
        char* supportedBrands[4];
        uint32_t supportedBrandsCount = 0;
        uint32_t flags = 0;

        if ([[attributes valueForKey:MP42Create64BitData] boolValue])
            flags += 0x01;

        if ([[attributes valueForKey:MP42Create64BitTime] boolValue])
            flags += 0x02;

        if ([fileExtension isEqualToString:MP42FileTypeM4V]) {
            majorBrand = "M4V ";
            supportedBrands[0] = majorBrand;
            supportedBrands[1] = "M4A ";
            supportedBrands[2] = "mp42";
            supportedBrands[3] = "isom";
            supportedBrandsCount = 4;
        }
        else if ([fileExtension isEqualToString:MP42FileTypeM4A] || [fileExtension isEqualToString:MP42FileTypeM4A]) {
            majorBrand = "M4A ";
            supportedBrands[0] = majorBrand;
            supportedBrands[1] = "mp42";
            supportedBrands[2] = "isom";
            supportedBrandsCount = 3;
        }
        else {
            supportedBrands[0] = majorBrand;
            supportedBrands[1] = "isom";
            supportedBrandsCount = 2;
        }

        fileHandle = MP4CreateEx([[fileURL path] UTF8String],
                                 flags, 1, 1,
                                 majorBrand, 0,
                                 supportedBrands, supportedBrandsCount);
        if (fileHandle) {
            MP4SetTimeScale(fileHandle, 600);
            MP4Close(fileHandle, 0);

            success = [self updateMP4FileWithAttributes:attributes error:outError];
        }
    }

    return success;
}

- (BOOL) updateMP4FileWithAttributes:(NSDictionary *)attributes error:(NSError **)outError
{
    BOOL success = YES;
    MP42Track *track;

    // Open the mp4 file
    fileHandle = MP4Modify([[fileURL path] UTF8String], 0);
    if (fileHandle == MP4_INVALID_FILE_HANDLE) {
        if ( outError != NULL)
            *outError = MP42Error(@"Unable to open the file",
                                  nil,
                                  100);

        return NO;
    }

    // Delete tracks
    for (track in tracksToBeDeleted)
        [self removeMuxedTrack:track];

    // Init the muxer and prepare the work
    muxer = [[MP42Muxer alloc] initWithDelegate:self];

    NSMutableDictionary *_fileImporters = [[NSMutableDictionary alloc] init];

    for (track in tracks)
        if (!(track.muxed) && !isCancelled) {
            // Reopen the file importer is they are not already open, this happens when the object has been unarchived from a file
            if (![track trackImporterHelper] && ![tracks isKindOfClass:[MP42ChapterTrack class]]) {
                MP42FileImporter *fileImporter = nil;
                NSURL *sourceURL = [track sourceURL];

                if ((fileImporter = [_fileImporters valueForKey:[[track sourceURL] path]])) {
                    [track setTrackImporterHelper:fileImporter];
                }
                else if (sourceURL) {
                    if([sourceURL respondsToSelector:@selector(startAccessingSecurityScopedResource)])
                        [sourceURL startAccessingSecurityScopedResource];

                    fileImporter = [[MP42FileImporter alloc] initWithDelegate:nil andFile:[track sourceURL] error:outError];
                    if (fileImporter) {
                        [track setTrackImporterHelper:fileImporter];
                        [_fileImporters setObject:fileImporter forKey:[[track sourceURL] path]];
                        [fileImporter release];
                    }
                }
            }
            [muxer addTrack:track];
    }


    success = [muxer prepareWork:fileHandle error:outError];
    if ( !success && outError != NULL) {
        [muxer release];
        [_fileImporters release];

        muxer = nil;

        return NO;
    }
    else {
        [muxer start:fileHandle];
        updateMoovDuration(fileHandle);
    }

    [muxer release];
    muxer = nil;

    // Stop accessing scoped bookmarks
    NSString* currentPath = nil;
    for (track in tracks) {
        NSURL *sourceURL = [track sourceURL];
        
        if ([[sourceURL path] isEqualToString:currentPath])
            continue;
        else {
            if([sourceURL respondsToSelector:@selector(stopAccessingSecurityScopedResource)])
                [sourceURL stopAccessingSecurityScopedResource];

            currentPath = [sourceURL path];
        }
    }

    [_fileImporters release];

    // Update modified tracks properties
    for (track in tracks)
        if (track.isEdited) {
            success = [track writeToFile:fileHandle error:outError];
            if (!success)
                break;
        }

    // Update metadata 
    if (metadata.isEdited)
        [metadata writeMetadataWithFileHandle:fileHandle];

    // Close the mp4 file handle
    MP4Close(fileHandle, 0);

    // Generate previews images for chapters
    if ([[attributes valueForKey:@"ChaptersPreview"] boolValue])
        [self createChaptersPreview];

    return success;
}

- (void) cancel;
{
    isCancelled = YES;
    [muxer cancel];
}

- (void)progressStatus: (CGFloat)progress {
    if ([delegate respondsToSelector:@selector(progressStatus:)]) 
        [delegate progressStatus:progress];
}

- (uint64_t)estimatedDataLength {
    uint64_t estimation = 0;
    for (MP42Track *track in tracks)
        estimation += track.dataLength;

    return estimation;
}

- (void) removeMuxedTrack: (MP42Track *)track
{
    if (!fileHandle)
        return;

    // We have to handle a few special cases here.
    if ([track isMemberOfClass:[MP42ChapterTrack class]]) {
        MP4ChapterType err = MP4DeleteChapters(fileHandle, MP4ChapterTypeAny, track.Id);
        if (err == 0)
            MP4DeleteTrack(fileHandle, track.Id);
    }
    else
        MP4DeleteTrack(fileHandle, track.Id);

    updateTracksCount(fileHandle);
    updateMoovDuration(fileHandle);

    if ([track isMemberOfClass:[MP42SubtitleTrack class]])
        enableFirstSubtitleTrack(fileHandle);
}

/* Create a set of alternate group the way iTunes and Apple devices want:
   one alternate group for sound, one for subtitles, a disabled photo-jpeg track,
   a disabled chapter track, and a video track with no alternate group */
- (void) iTunesFriendlyTrackGroups
{
    NSInteger firstAudioTrack = 0, firstSubtitleTrack = 0, firstVideoTrack = 0;

    for (MP42Track * track in tracks) {
        if ([track isMemberOfClass:[MP42ChapterTrack class]])
            track.enabled = NO;
        else if ([track isMemberOfClass:[MP42AudioTrack class]]) {
            if (!firstAudioTrack)
                track.enabled = YES;
            else
                track.enabled = NO;
            
            track.alternate_group = 1;
            firstAudioTrack++;
        }
        else if ([track isMemberOfClass:[MP42SubtitleTrack class]]) {
            if (!firstSubtitleTrack)
                track.enabled = YES;
            else
                track.enabled = NO;
            
            track.alternate_group = 2;
            firstSubtitleTrack++;
        }
        else if ([track isMemberOfClass:[MP42VideoTrack class]]) {
            track.alternate_group = 0;
            if ([track.format isEqualToString:@"Photo - JPEG"])
                track.enabled = NO;
            else {
                if (!firstVideoTrack) {
                    track.enabled = YES;
                    firstVideoTrack++;
                }
            }
        }
    }
}

- (BOOL) createChaptersPreview {
    NSError *error;
    NSInteger decodable = 1;
    MP42ChapterTrack * chapterTrack = nil;
    MP4TrackId jpegTrack = 0;

    for (MP42Track * track in tracks)
        if ([track isMemberOfClass:[MP42ChapterTrack class]])
            chapterTrack = (MP42ChapterTrack*) track;

    for (MP42Track * track in tracks)
        if ([track.format isEqualToString:@"Photo - JPEG"])
            jpegTrack = track.Id;

    for (MP42VideoTrack * track in tracks)
        if ([track.format isEqualToString:@"H.264"])
            if ((track.origProfile) == 110)
                decodable = 0;

    if (chapterTrack && !jpegTrack && decodable) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSMutableArray * previewImages = [NSMutableArray arrayWithCapacity:[chapterTrack chapterCount]];

        // If we are on 10.7, use the AVFoundation path
        if (NSClassFromString(@"AVAsset")) {
            #if __MAC_OS_X_VERSION_MAX_ALLOWED > 1060
            AVAsset *asset = [AVAsset assetWithURL:fileURL];

            if ([asset tracksWithMediaCharacteristic:AVMediaCharacteristicVisual]) {
                AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
                generator.appliesPreferredTrackTransform = YES;
                generator.apertureMode = AVAssetImageGeneratorApertureModeCleanAperture;
                generator.requestedTimeToleranceBefore = kCMTimeZero;
                generator.requestedTimeToleranceAfter  = kCMTimeZero;

                for (SBTextSample * chapter in [chapterTrack chapters]) {
                    CMTime time = CMTimeMake([chapter timestamp] + 1800, 1000);
                    CGImageRef imgRef = [generator copyCGImageAtTime:time actualTime:NULL error:&error];
                    if (imgRef) {
                        NSSize size = NSMakeSize(CGImageGetWidth(imgRef), CGImageGetHeight(imgRef));
                        NSImage *previewImage = [[NSImage alloc] initWithCGImage:imgRef size:size];

                        [previewImages addObject:previewImage];
                        [previewImage release];
                    }
                    else
                        NSLog(@"code: %d, domain: %@, userInfo: %@", [error code], [error domain], [error userInfo]);

                    CGImageRelease(imgRef);
                }
            }
            #endif
        }
        // Else fall back to QTKit
        else {
            __block QTMovie * qtMovie;
            // QTMovie objects must always be create on the main thread.
            NSDictionary *movieAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                                 fileURL, QTMovieURLAttribute,
                                                 [NSNumber numberWithBool:NO], QTMovieAskUnresolvedDataRefsAttribute,
                                                 [NSNumber numberWithBool:YES], @"QTMovieOpenForPlaybackAttribute",
                                                 [NSNumber numberWithBool:NO], @"QTMovieOpenAsyncRequiredAttribute",
                                                 [NSNumber numberWithBool:NO], @"QTMovieOpenAsyncOKAttribute",
                                                 QTMovieApertureModeClean, QTMovieApertureModeAttribute,
                                                 nil];
            if (dispatch_get_current_queue() != dispatch_get_main_queue()) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    qtMovie = [[QTMovie alloc] initWithAttributes:movieAttributes error:nil];
                });
            }
            else
                qtMovie = [[QTMovie alloc] initWithAttributes:movieAttributes error:nil];


            if (!qtMovie)
                return NO;

            for (QTTrack* qtTrack in [qtMovie tracksOfMediaType:@"sbtl"])
                [qtTrack setAttribute:[NSNumber numberWithBool:NO] forKey:QTTrackEnabledAttribute];

            NSDictionary *attributes = [NSDictionary dictionaryWithObject:QTMovieFrameImageTypeNSImage forKey:QTMovieFrameImageType];

            for (SBTextSample * chapter in [chapterTrack chapters]) {
                QTTime chapterTime = {
                    [chapter timestamp] + 1500, // Add a short offset, hopefully we will get a better image
                    1000,                       // if there is a fade
                    0
                };

                NSImage *previewImage = [qtMovie frameImageAtTime:chapterTime withAttributes:attributes error:&error];
                if (previewImage)
                    [previewImages addObject:previewImage];
                else {
                    NSLog(@"code: %d, domain: %@, userInfo: %@", [error code], [error domain], [error userInfo]);

                    [previewImages addObject:[NSNull null]];
                }
            }

            // Release the movie, we don't want to keep it open while we are writing in it using another library.
            // I am not sure if it is safe to release a QTMovie from a background thread, let's do it on the main just to be sure.
            if (dispatch_get_current_queue() != dispatch_get_main_queue()) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [qtMovie release];
                });
            }
            else
                [qtMovie release];
        }
        // If we haven't got enought images, return.
        if (([previewImages count] < [[chapterTrack chapters] count]) || [previewImages count] == 0 ) {
            [pool release];
            return NO;
        }

        // Reopen the mp4v2 fileHandle
        fileHandle = MP4Modify([[fileURL path] UTF8String], 0);
        if (fileHandle == MP4_INVALID_FILE_HANDLE)
            return NO;

        MP4TrackId refTrack = findFirstVideoTrack(fileHandle);
        if (!refTrack)
            refTrack = 1;

        CGFloat maxWidth = 640;
        NSSize imageSize = [[previewImages objectAtIndex:0] size];
        if (imageSize.width > maxWidth) {
            imageSize.height = maxWidth / imageSize.width * imageSize.height;
            imageSize.width = maxWidth;
        }

        jpegTrack = MP4AddJpegVideoTrack(fileHandle, MP4GetTrackTimeScale(fileHandle, [chapterTrack Id]),
                                          MP4_INVALID_DURATION, imageSize.width, imageSize.height);

        NSString *language = @"Unknown";
        for (MP42Track * track in tracks)
            if ([track isMemberOfClass:[MP42VideoTrack class]])
                language = ((MP42VideoTrack*) track).language;

        MP4SetTrackLanguage(fileHandle, jpegTrack, lang_for_english([language UTF8String])->iso639_2);

        MP4SetTrackIntegerProperty(fileHandle, jpegTrack, "tkhd.layer", 1);
        disableTrack(fileHandle, jpegTrack);

        NSInteger i = 0;
        MP4Duration duration = 0;

        for (SBTextSample *chapterT in [chapterTrack chapters]) {
            duration = MP4GetSampleDuration(fileHandle, [chapterTrack Id], i+1);

            // Scale the image.
            NSRect newRect = NSMakeRect(0.0, 0.0, imageSize.width, imageSize.height);
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                               pixelsWide:newRect.size.width
                                                                               pixelsHigh:newRect.size.height
                                                                            bitsPerSample:8
                                                                          samplesPerPixel:4
                                                                                 hasAlpha:YES
                                                                                 isPlanar:NO
                                                                           colorSpaceName:NSCalibratedRGBColorSpace
                                                                             bitmapFormat:NSAlphaFirstBitmapFormat
                                                                              bytesPerRow:0
                                                                             bitsPerPixel:32];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];

            [[previewImages objectAtIndex:0] drawInRect:newRect fromRect:NSZeroRect operation:NSCompositeCopy fraction:1.0];

            [NSGraphicsContext restoreGraphicsState];

            NSData * jpegData = [bitmap representationUsingType:NSJPEGFileType properties:nil];
            [bitmap release];

            i++;
            MP4WriteSample(fileHandle,
                           jpegTrack,
                           [jpegData bytes],
                           [jpegData length],
                           duration,
                           0,
                           true);

            [previewImages removeObjectAtIndex:0];
        }

        MP4RemoveAllTrackReferences(fileHandle, "tref.chap", refTrack);
        MP4AddTrackReference(fileHandle, "tref.chap", [chapterTrack Id], refTrack);
        MP4AddTrackReference(fileHandle, "tref.chap", jpegTrack, refTrack);
        copyTrackEditLists(fileHandle, [chapterTrack Id], jpegTrack);

        MP4Close(fileHandle, 0);

        [pool release];
        return YES;
    }
    else if (chapterTrack && jpegTrack) {
        // We already have all the tracks, so hook them up.
        fileHandle = MP4Modify([[fileURL path] UTF8String], 0);
        if (fileHandle == MP4_INVALID_FILE_HANDLE)
            return NO;

        MP4TrackId refTrack = findFirstVideoTrack(fileHandle);
        if (!refTrack)
            refTrack = 1;

        MP4RemoveAllTrackReferences(fileHandle, "tref.chap", refTrack);
        MP4AddTrackReference(fileHandle, "tref.chap", [chapterTrack Id], refTrack);
        MP4AddTrackReference(fileHandle, "tref.chap", jpegTrack, refTrack);
        MP4Close(fileHandle, 0);
    }

    return NO;
}

@synthesize delegate;
@synthesize URL = fileURL;
@synthesize tracks;
@synthesize metadata;
@synthesize hasFileRepresentation;

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:2 forKey:@"MP42FileVersion"];

    if ([fileURL respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
            NSData *bookmarkData = nil;
            NSError *error = nil;
            bookmarkData = [fileURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                             includingResourceValuesForKeys:nil
                                              relativeToURL:nil // Make it app-scoped
                                                      error:&error];
        if (error) {
            NSLog(@"Error creating bookmark for URL (%@): %@", fileURL, error);
        }
        
        [coder encodeObject:bookmarkData forKey:@"bookmark"];

    }
    else {
        [coder encodeObject:fileURL forKey:@"fileUrl"];
    }

    [coder encodeObject:tracksToBeDeleted forKey:@"tracksToBeDeleted"];
    [coder encodeBool:hasFileRepresentation forKey:@"hasFileRepresentation"];

    [coder encodeObject:tracks forKey:@"tracks"];
    [coder encodeObject:metadata forKey:@"metadata"];
}

- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super init];

    NSData *bookmarkData = [decoder decodeObjectForKey:@"bookmark"];
    if (bookmarkData) {
        BOOL bookmarkDataIsStale;
        NSError *error;
        fileURL = [[NSURL
                    URLByResolvingBookmarkData:bookmarkData
                    options:NSURLBookmarkResolutionWithSecurityScope
                    relativeToURL:nil
                    bookmarkDataIsStale:&bookmarkDataIsStale
                    error:&error] retain];
    }
    else {
        fileURL = [[decoder decodeObjectForKey:@"fileUrl"] retain];
    }

    tracksToBeDeleted = [[decoder decodeObjectForKey:@"tracksToBeDeleted"] retain];

    hasFileRepresentation = [decoder decodeBoolForKey:@"hasFileRepresentation"];

    tracks = [[decoder decodeObjectForKey:@"tracks"] retain];
    metadata = [[decoder decodeObjectForKey:@"metadata"] retain];

    return self;
}

- (void) dealloc
{
    [fileURL release];
    [tracks release];
    [fileImporters release];
    [tracksToBeDeleted release];
    [metadata release];
    [super dealloc];
}

@end
