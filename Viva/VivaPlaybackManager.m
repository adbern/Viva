//
//  VivaPlaybackManager.m
//  Viva
//
//  Created by Daniel Kennett on 3/30/11.
//  Copyright 2011 Spotify. All rights reserved.
//

#import "VivaPlaybackManager.h"
#import "Constants.h"

@interface VivaPlaybackManager  ()

@property (retain, readwrite) SPCircularBuffer *audioBuffer;
@property (retain, readwrite) CoCAAudioUnit *audioUnit;
@property (retain, readwrite) id <VivaPlaybackContext> playbackContext;
@property (readwrite, retain) id <VivaTrackContainer> currentTrackContainer;
@property (readwrite, retain) SPSession *playbackSession;

-(void)playTrackContainerInCurrentContext:(id <VivaTrackContainer>)newTrack;

-(id <VivaTrackContainer>)nextTrackContainerInCurrentContext;
-(id <VivaTrackContainer>)previousTrackContainerInCurrentContext;

//vDSP 

- (CGFloat)performAcceleratedFastFourierTransformWithWaveform:(float *)waveformArray intoStore:(double *)magnitudes;

@property (readwrite, retain) NSArray *leftLevels;
@property (readwrite, retain) NSArray *rightLevels;

@end

#define kMaximumBytesInBuffer 44100 * 2 * 2 * 0.5 // 0.5 Second @ 44.1kHz, 16bit per channel, stereo

static NSUInteger const fftWaveCount = 512;
static NSUInteger const fftMagnitudeCount = 10;

@implementation VivaPlaybackManager

- (id)initWithPlaybackSession:(SPSession *)aSession {
    self = [super init];
    if (self) {
        // Initialization code here.
		
		SEL setTrackPositionSelector = @selector(setCurrentTrackPosition:);
		setTrackPositionMethodSignature = [[VivaPlaybackManager instanceMethodSignatureForSelector:setTrackPositionSelector] retain];
		setTrackPositionInvocation = [[NSInvocation invocationWithMethodSignature:setTrackPositionMethodSignature] retain];
		[setTrackPositionInvocation setSelector:setTrackPositionSelector];
		[setTrackPositionInvocation setTarget:self];
		
		self.volume = 1.0;
		self.playbackSession = aSession;
		self.playbackSession.playbackDelegate = self;
        
		self.audioBuffer = [[[SPCircularBuffer alloc] initWithMaximumLength:kMaximumBytesInBuffer] autorelease];
		
        [self addObserver:self
               forKeyPath:@"playbackSession.playing"
                  options:0
                  context:nil];
		
		[self addObserver:self
			   forKeyPath:@"currentTrackContainer"
				  options:0
				  context:nil];
		
		[self addObserver:self
			   forKeyPath:@"currentTrackPosition"
				  options:0
				  context:nil];
		
		[self addObserver:self
			   forKeyPath:@"playbackContext"
				  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
				  context:nil];
		
		// Playback
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(playTrackFromUserAction:)
													 name:kTrackShouldBePlayedNotification
												   object:nil];

		/* Setup weights (twiddle factors) */
		fft_weights = vDSP_create_fftsetupD(6, kFFTRadix2);
		
		/* Allocate memory to store split-complex input and output data */
		input.realp = (double *)malloc(fftWaveCount * sizeof(double));
		input.imagp = (double *)malloc(fftWaveCount * sizeof(double));
		leftChannelMagnitudes = (double *)malloc(fftMagnitudeCount * sizeof(double));
		rightChannelMagnitudes = (double *)malloc(fftMagnitudeCount * sizeof(double));
    }
    
    return self;
}

@synthesize audioBuffer;
@synthesize audioUnit;
@synthesize playbackContext;
@synthesize currentTrackContainer;
@synthesize playbackSession;
@synthesize currentTrackPosition;
@synthesize volume;
@synthesize loopPlayback;

@synthesize leftLevels;
@synthesize rightLevels;

+(NSSet *)keyPathsForValuesAffectingCurrentTrack {
	return [NSSet setWithObjects:@"currentTrackContainer.track", nil];
}

-(SPTrack *)currentTrack {
	return self.currentTrackContainer.track;
}

+(NSSet *)keyPathsForValuesAffectingCanSkipToNextTrack {
	return [NSSet setWithObjects:@"loopPlayback", @"currentTrack", @"playbackContext.trackContainersForPlayback", nil];
}

-(BOOL)canSkipToNextTrack {
	return (self.loopPlayback || 
			[self.playbackContext.trackContainersForPlayback indexOfObject:self.currentTrackContainer] != [self.playbackContext.trackContainersForPlayback count] - 1);			
}

+(NSSet *)keyPathsForValuesAffectingCanSkipToPreviousTrack {
	return [NSSet setWithObjects:@"loopPlayback", @"currentTrack", @"playbackContext.trackContainersForPlayback", nil];
}

-(BOOL)canSkipToPreviousTrack {
	return (self.loopPlayback || 
			[self.playbackContext.trackContainersForPlayback indexOfObject:self.currentTrack] != 0);			
}

#pragma mark -

-(void)playTrackFromUserAction:(NSNotification *)aNotification {
	
	// User double-clicked, so reset everything and start again.
	[self.playbackSession setPlaying:NO];
	[self.playbackSession unloadPlayback];
	[self.audioUnit stop];
	self.audioUnit = nil;
	
	[self.audioBuffer clear];
	
	id <VivaTrackContainer> container = [[aNotification userInfo] valueForKey:kPlaybackInitialTrackContainerKey];
	
	if ([[aNotification object] conformsToProtocol:@protocol(VivaPlaybackContext)]) {
		self.playbackContext = [aNotification object];
	}
	
	[self playTrackContainerInCurrentContext:container];
	self.playbackSession.playing = YES;
}

-(void)playTrackContainerInCurrentContext:(id <VivaTrackContainer>)newTrack {
	
	// Don't clear out the audio buffer just in case we can manage gapless playback.
	self.currentTrackContainer = newTrack;
	self.currentTrackPosition = 0.0;
	[self.playbackSession playTrack:self.currentTrackContainer.track error:nil];
}
	
-(void)seekToTrackPosition:(NSTimeInterval)newPosition {
	if (newPosition <= self.currentTrack.duration) {
		[self.playbackSession seekPlaybackToOffset:newPosition];
		self.currentTrackPosition = newPosition;
	}	
}

-(id <VivaTrackContainer>)nextTrackContainerInCurrentContext {
	
	NSUInteger currentTrackIndex = [self.playbackContext.trackContainersForPlayback indexOfObject:self.currentTrackContainer];
	
	if (currentTrackIndex == NSNotFound ||
		(currentTrackIndex == [self.playbackContext.trackContainersForPlayback count] - 1 && !self.loopPlayback)) {
		return nil;
	} else if (currentTrackIndex == [self.playbackContext.trackContainersForPlayback count] - 1) {
		return [self.playbackContext.trackContainersForPlayback objectAtIndex:0];
	} else {
		return [self.playbackContext.trackContainersForPlayback objectAtIndex:currentTrackIndex + 1];
	}
}

-(void)skipToNextTrackInCurrentContext:(BOOL)clearExistingAudioBuffers {
	
	BOOL wasPlaying = self.playbackSession.playing;
	
	if (clearExistingAudioBuffers) {
		[self.playbackSession setPlaying:NO];
		[self.playbackSession unloadPlayback];
		[self.audioUnit stop];
		self.audioUnit = nil;
		
		[self.audioBuffer clear];
	}
	
	id <VivaTrackContainer> nextContainer = [self nextTrackContainerInCurrentContext];
	
	if (nextContainer != nil) {
		[self playTrackContainerInCurrentContext:nextContainer];	
		self.playbackSession.playing = wasPlaying;
	} else {
		self.currentTrackContainer = nil;
		[self.audioUnit stop];
		self.audioUnit = nil;
		self.currentTrackPosition = 0;
	}
}

-(id <VivaTrackContainer>)previousTrackContainerInCurrentContext {
	
	NSUInteger currentTrackIndex = [self.playbackContext.trackContainersForPlayback indexOfObject:self.currentTrackContainer];
	
	if (currentTrackIndex == NSNotFound ||
		(currentTrackIndex == 0 && !self.loopPlayback)) {
		return nil;
	} else if (currentTrackIndex == 0) {
		return [self.playbackContext.trackContainersForPlayback objectAtIndex:[self.playbackContext.trackContainersForPlayback count] - 1];
	} else {
		return [self.playbackContext.trackContainersForPlayback objectAtIndex:currentTrackIndex - 1];
	}
}

-(void)skipToPreviousTrackInCurrentContext:(BOOL)clearExistingAudioBuffers {
	
	BOOL wasPlaying = self.playbackSession.playing;
	
	if (clearExistingAudioBuffers) {
		[self.playbackSession setPlaying:NO];
		[self.playbackSession unloadPlayback];
		[self.audioUnit stop];
		self.audioUnit = nil;
		
		[self.audioBuffer clear];
	}
	
	id <VivaTrackContainer> previousContainer = [self previousTrackContainerInCurrentContext];
	
	if (previousContainer != nil) {
		[self playTrackContainerInCurrentContext:previousContainer];	
		self.playbackSession.playing = wasPlaying;
	} else {
		self.currentTrackContainer = nil;
		[self.audioUnit stop];
		self.audioUnit = nil;
		self.currentTrackPosition = 0;
	}
}

#pragma mark -
#pragma mark Playback Callbacks

-(void)sessionDidLosePlayToken:(SPSession *)aSession {}

-(void)sessionDidEndPlayback:(SPSession *)aSession {
	// Not routing this through to the main thread causes odd locks and crashes.
	[self performSelectorOnMainThread:@selector(sessionDidEndPlaybackOnMainThread:)
						   withObject:aSession
						waitUntilDone:NO];
}

-(void)sessionDidEndPlaybackOnMainThread:(SPSession *)aSession {
	[self skipToNextTrackInCurrentContext:NO];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"playbackSession.playing"]) {
        
        if (self.playbackSession.playing) {
            [self.audioUnit start];
        } else {
            [self.audioUnit stop];
        }
		
		if ([self.playbackContext respondsToSelector:@selector(setPlayingTrackContainer:isPlaying:)]) {
			[self.playbackContext setPlayingTrackContainer:self.currentTrackContainer isPlaying:self.playbackSession.isPlaying];
		}
		
	} else if ([keyPath isEqualToString:@"currentTrackContainer"]) {
		@synchronized(self) {
			hasPreCachedNextTrack = NO;
		}
		
		if ([self.playbackContext respondsToSelector:@selector(setPlayingTrackContainer:isPlaying:)]) {
			[self.playbackContext setPlayingTrackContainer:self.currentTrackContainer isPlaying:self.playbackSession.isPlaying];
		}
		
	} else if ([keyPath isEqualToString:@"playbackContext"]) {
		
		id oldContext = [change valueForKey:NSKeyValueChangeOldKey];
		if (oldContext != nil && oldContext != [NSNull null]) {
			if ([oldContext respondsToSelector:@selector(setPlayingTrackContainer:isPlaying:)]) {
				[oldContext setPlayingTrackContainer:nil isPlaying:NO];
			}
		}
		
		id newContext = [change valueForKey:NSKeyValueChangeNewKey];
		if (newContext != nil && newContext != [NSNull null]) {
			if ([newContext respondsToSelector:@selector(setPlayingTrackContainer:isPlaying:)]) {
				[newContext setPlayingTrackContainer:self.currentTrackContainer isPlaying:self.playbackSession.isPlaying];
			}
		}
		
	} else if ([keyPath isEqualToString:@"currentTrackPosition"]) {
		if (!hasPreCachedNextTrack && self.currentTrack.duration - self.currentTrackPosition <= kNextTrackCacheThreshold) {
			id <VivaTrackContainer> nextContainer = [self nextTrackContainerInCurrentContext];
			if (nextContainer != nil) {
				[self.playbackSession preloadTrackForPlayback:nextContainer.track error:nil];
				@synchronized(self) {
					hasPreCachedNextTrack = YES;
				}
			}
		}
        
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark Audio Processing

-(NSInteger)session:(SPSession *)aSession shouldDeliverAudioFrames:(const void *)audioFrames ofCount:(NSInteger)frameCount format:(const sp_audioformat *)audioFormat {
	
	if (frameCount == 0) {
		[self.audioBuffer clear];
		return 0; // Audio discontinuity!
	}
	
	NSUInteger frameByteSize = sizeof(sint16) * audioFormat->channels;
	NSUInteger dataLength = frameCount * frameByteSize;
	
	if ((self.audioBuffer.maximumLength - self.audioBuffer.length) < dataLength) {
		// Only allow whole deliveries in, since libSpotify wants us to consume whole frames, whereas
		// the buffer works in bytes, meaning we could consume a fraction of a frame.
		return 0;
	}
	
	[self.audioBuffer attemptAppendData:audioFrames ofLength:dataLength];
	
	if (self.audioUnit == nil) {
		self.audioUnit = [CoCAAudioUnit defaultOutputUnit];
		[self.audioUnit setRenderDelegate:self];
		[self.audioUnit setup];
    }
	
    [self.audioUnit start];
	
	return frameCount;
}

static UInt32 framesSinceLastUpdate = 0;

-(OSStatus)audioUnit:(CoCAAudioUnit*)audioUnit
     renderWithFlags:(AudioUnitRenderActionFlags*)ioActionFlags
                  at:(const AudioTimeStamp*)inTimeStamp
               onBus:(UInt32)inBusNumber
          frameCount:(UInt32)inNumberFrames
           audioData:(AudioBufferList *)ioData;
{	
	
	// Core Audio generally expects audio data to be in native-endian 32-bit floating-point linear PCM format.
	
	AudioBuffer *leftBuffer = &(ioData->mBuffers[0]);
	AudioBuffer *rightBuffer = &(ioData->mBuffers[1]);
	
	NSUInteger bytesRequired = inNumberFrames * 2 * 2; // 16bit per channel, stereo
	void *frameBuffer = NULL;

	NSUInteger availableData = [audioBuffer length];
	if (availableData >= bytesRequired) {
		 [audioBuffer readDataOfLength:bytesRequired intoBuffer:&frameBuffer];
	} else {
		leftBuffer->mDataByteSize = 0;
		rightBuffer->mDataByteSize = 0;
		*ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
		return noErr;
	}
	
	float *leftChannelBuffer = leftBuffer->mData;
	float *rightChannelBuffer = rightBuffer->mData;
	
	sint16 *frames = frameBuffer;
	double effectiveVolume = self.volume;
	
	for (NSUInteger currentFrame = 0; currentFrame < inNumberFrames; currentFrame++) {

		// Convert the frames from 16-bit signed integers to floating point, then apply the volume.
		leftChannelBuffer[currentFrame] = (frames[currentFrame * 2]/(float)INT16_MAX) * effectiveVolume;
		rightChannelBuffer[currentFrame] = (frames[(currentFrame * 2) + 1]/(float)INT16_MAX) * effectiveVolume;
	}
	
	if (frameBuffer != NULL) 
		free(frameBuffer);
	frames = NULL;
	
	framesSinceLastUpdate += inNumberFrames;
	
	if (framesSinceLastUpdate >= 2205) {
		// Update 5 times per second. (Should be 8820)
		
		NSTimeInterval newTrackPosition = self.currentTrackPosition + (double)framesSinceLastUpdate/44100.0;
		
		[setTrackPositionInvocation setArgument:&newTrackPosition atIndex:2];
		[setTrackPositionInvocation performSelectorOnMainThread:@selector(invoke)
									   withObject:nil
									waitUntilDone:NO];		
		
		// vDSP
		
		if (inNumberFrames == fftWaveCount) {
			[self performAcceleratedFastFourierTransformWithWaveform:leftChannelBuffer intoStore:leftChannelMagnitudes];
			[self performAcceleratedFastFourierTransformWithWaveform:rightChannelBuffer intoStore:rightChannelMagnitudes];		
		} else {
			NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Mismatch in data sizes; bailing.");
		}
		
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		
		NSMutableArray *left = [[NSMutableArray alloc] initWithCapacity:fftMagnitudeCount];
		NSMutableArray *right = [[NSMutableArray alloc] initWithCapacity:fftMagnitudeCount];
		
		for (int currentLevel = 0; currentLevel < fftMagnitudeCount; currentLevel++) {
			[left addObject:[NSNumber numberWithDouble:sqrt(leftChannelMagnitudes[currentLevel])]];
			[right addObject:[NSNumber numberWithDouble:sqrt(rightChannelMagnitudes[currentLevel])]];
		}
		
		[self performSelectorOnMainThread:@selector(setLeftLevels:) withObject:left waitUntilDone:NO];
		[self performSelectorOnMainThread:@selector(setRightLevels:) withObject:right waitUntilDone:NO];
		
		[pool drain];
		
		// END vDSP
		
		framesSinceLastUpdate = 0;
		
	}
    
    return noErr;
}


- (void)performAcceleratedFastFourierTransformWithWaveform:(float *)waveformArray intoStore:(double *)magnitudes;
{   
	if (magnitudes == NULL || waveformArray == NULL)
		return;
	
    for (NSUInteger currentInputSampleIndex = 0; currentInputSampleIndex < fftWaveCount; currentInputSampleIndex++) {
        input.realp[currentInputSampleIndex] = (double)waveformArray[currentInputSampleIndex];
        input.imagp[currentInputSampleIndex] = 0.0f;
    }
	
    /* 1D in-place complex FFT */
    vDSP_fft_zipD(fft_weights, &input, 1, 6, FFT_FORWARD);
	
    // Get magnitudes
    vDSP_zvmagsD(&input, 1, magnitudes, 1, fftMagnitudeCount);
}

#pragma mark -

- (void)dealloc {

    [self removeObserver:self forKeyPath:@"playbackSession.playing"];
	[self removeObserver:self forKeyPath:@"currentTrackContainer"];
	[self removeObserver:self forKeyPath:@"currentTrackPosition"];
	[self removeObserver:self forKeyPath:@"playbackContext"];
	
	[setTrackPositionInvocation release];
	[setTrackPositionMethodSignature release];
	
	[self.audioBuffer clear];
	self.audioBuffer = nil;
    self.currentTrackContainer = nil;
	self.playbackContext = nil;
	[self.audioUnit stop];
	self.audioUnit = nil;
	self.playbackSession = nil;
	
	// vDSP
	free(input.realp);
	free(input.imagp);
	free(leftChannelMagnitudes);
	free(rightChannelMagnitudes);
	
	self.leftLevels = nil;
	self.rightLevels = nil;

    [super dealloc];
}

@end
