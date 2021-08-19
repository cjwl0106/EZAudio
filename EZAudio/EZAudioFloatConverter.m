//
//  EZAudioFloatConverter.m
//  EZAudio
//
//  Created by Syed Haris Ali on 6/23/15.
//  Copyright (c) 2015 Syed Haris Ali. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "EZAudioFloatConverter.h"
#import "EZAudioUtilities.h"

//------------------------------------------------------------------------------
#pragma mark - Constants
//------------------------------------------------------------------------------

static UInt32 EZAudioFloatConverterDefaultOutputBufferSize = 128 * 32;
UInt32 const EZAudioFloatConverterDefaultPacketSize = 2048;

//------------------------------------------------------------------------------
#pragma mark - Data Structures
//------------------------------------------------------------------------------

typedef struct
{
    AudioConverterRef             converterRef;
    AudioBufferList              *floatAudioBufferList;
    AudioStreamBasicDescription   inputFormat;
    AudioStreamBasicDescription   outputFormat;
    AudioStreamPacketDescription *packetDescriptions;
    UInt32 packetsPerBuffer;
} EZAudioFloatConverterInfo;

//------------------------------------------------------------------------------
#pragma mark - Callbacks
//------------------------------------------------------------------------------
typedef struct {
	UInt32 frameOffset;
	UInt32 frameSize;
	UInt32 frameQuantity;
	AudioBufferList *sourceBuffer;
	int special;
} ConverterUserData;


OSStatus EZAudioFloatConverterCallback(AudioConverterRef             inAudioConverter,
                                       UInt32                       *ioNumberDataPackets,
                                       AudioBufferList              *ioData,
                                       AudioStreamPacketDescription **outDataPacketDescription,
                                       void                         *inUserData_)
{
	ConverterUserData *inUserData = (ConverterUserData *)inUserData_;
    AudioBufferList *sourceBuffer = inUserData->sourceBuffer;
    
    if (inUserData->special)
    {
		int x = 0;
		x++;
	}
    
    int byteOffset = inUserData->frameOffset * inUserData->frameSize;
    int byteSize = inUserData->frameQuantity * inUserData->frameSize;
    
    ioData->mNumberBuffers = sourceBuffer->mNumberBuffers;
    
	for (size_t i=0; i<sourceBuffer->mNumberBuffers; ++i)
	{
		AudioBuffer *to = &ioData->mBuffers[i];
		AudioBuffer *from = &sourceBuffer->mBuffers[i];
		
		to->mData = from->mData + byteOffset;
		to->mNumberChannels = from->mNumberChannels;
		to->mDataByteSize = byteSize;
	}
    
    return noErr;
}

//------------------------------------------------------------------------------
#pragma mark - EZAudioFloatConverter (Interface Extension)
//------------------------------------------------------------------------------

@interface EZAudioFloatConverter ()
@property (nonatomic, assign) EZAudioFloatConverterInfo *info;
@end

//------------------------------------------------------------------------------
#pragma mark - EZAudioFloatConverter (Implementation)
//------------------------------------------------------------------------------

@implementation EZAudioFloatConverter

//------------------------------------------------------------------------------
#pragma mark - Class Methods
//------------------------------------------------------------------------------

+ (instancetype)converterWithInputFormat:(AudioStreamBasicDescription)inputFormat
{
    return [[self alloc] initWithInputFormat:inputFormat numberOfFrames:0];
}

//------------------------------------------------------------------------------
#pragma mark - Dealloc
//------------------------------------------------------------------------------

- (void)dealloc
{
    AudioConverterDispose(self.info->converterRef);
    [EZAudioUtilities freeBufferList:self.info->floatAudioBufferList];
    free(self.info->packetDescriptions);
    free(self.info);
}

//------------------------------------------------------------------------------
#pragma mark - Initialization
//------------------------------------------------------------------------------

- (instancetype)initWithInputFormat:(AudioStreamBasicDescription)inputFormat numberOfFrames:(UInt32)numberOfFrames
{
    self = [super init];
    if (self)
    {
        self.info = (EZAudioFloatConverterInfo *)malloc(sizeof(EZAudioFloatConverterInfo));
        memset(self.info, 0, sizeof(EZAudioFloatConverterInfo));
        self.info->inputFormat = inputFormat;
        [self setup:numberOfFrames];
    }
    return self;
}

//------------------------------------------------------------------------------
#pragma mark - Setup
//------------------------------------------------------------------------------

- (void)setup:(UInt32)numberOfFrames
{
    // create output format
    self.info->outputFormat = [EZAudioUtilities floatFormatWithNumberOfChannels:self.info->inputFormat.mChannelsPerFrame
                                                                     sampleRate:self.info->inputFormat.mSampleRate];
    
    // create a new instance of the audio converter
    [EZAudioUtilities checkResult:AudioConverterNew(&self.info->inputFormat,
                                                    &self.info->outputFormat,
                                                    &self.info->converterRef)
                        operation:"Failed to create new audio converter"];
    
    /*
    // get max packets per buffer so you can allocate a proper AudioBufferList
    UInt32 packetsPerBuffer = 0;
    UInt32 outputBufferSize = EZAudioFloatConverterDefaultOutputBufferSize;
    UInt32 sizePerPacket = self.info->inputFormat.mBytesPerPacket;
    BOOL isVBR = sizePerPacket == 0;
    
    // VBR
    if (isVBR)
    {
        // determine the max output buffer size
        UInt32 maxOutputPacketSize;
        UInt32 propSize = sizeof(maxOutputPacketSize);
        OSStatus result = AudioConverterGetProperty(self.info->converterRef,
                                                    kAudioConverterPropertyMaximumOutputPacketSize,
                                                    &propSize,
                                                    &maxOutputPacketSize);
        if (result != noErr)
        {
            maxOutputPacketSize = EZAudioFloatConverterDefaultPacketSize;
        }
        
        // set the output buffer size to at least the max output size
        if (maxOutputPacketSize > outputBufferSize)
        {
            outputBufferSize = maxOutputPacketSize;
        }
        packetsPerBuffer = outputBufferSize / maxOutputPacketSize;
        
        // allocate memory for the packet descriptions
        self.info->packetDescriptions = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * packetsPerBuffer);
    }
    else
    {
        packetsPerBuffer = outputBufferSize / sizePerPacket;
    }
    self.info->packetsPerBuffer = packetsPerBuffer;

    */
    

    self.info->packetsPerBuffer = numberOfFrames;
    
    // allocate the AudioBufferList to hold the float values
    BOOL isInterleaved = [EZAudioUtilities isInterleaved:self.info->outputFormat];
    self.info->floatAudioBufferList = [EZAudioUtilities audioBufferListWithNumberOfFrames:numberOfFrames
                                                                         numberOfChannels:self.info->outputFormat.mChannelsPerFrame
                                                                              interleaved:isInterleaved];
}

//------------------------------------------------------------------------------
#pragma mark - Events
//------------------------------------------------------------------------------

- (void)convertDataFromAudioBufferList:(AudioBufferList *)audioBufferList
                    withNumberOfFrames:(UInt32)frames
                        toFloatBuffers:(float **)buffers
{
    [self convertDataFromAudioBufferList:audioBufferList
                      withNumberOfFrames:frames
                          toFloatBuffers:buffers
                      packetDescriptions:self.info->packetDescriptions];
}

//------------------------------------------------------------------------------

- (void)convertDataFromAudioBufferList:(AudioBufferList *)audioBufferList
                    withNumberOfFrames:(UInt32)availableFrames
                        toFloatBuffers:(float **)buffers
                    packetDescriptions:(AudioStreamPacketDescription *)packetDescriptions
{
	if (availableFrames > 4096)
		availableFrames = 4096;
	
	ConverterUserData userData;
	userData.frameOffset = 0;
	userData.frameSize = self.info->inputFormat.mBytesPerFrame;
	userData.sourceBuffer = audioBufferList;
	userData.special = 0;
	
	while (availableFrames > 0)
	{
        UInt32 frames = availableFrames < 512 ? availableFrames : 512;
		userData.frameQuantity = frames;
		
		if (availableFrames > 1024)
			userData.special = 1;
        
        //
        // Fill out the audio converter with the source buffer
        //
        AudioConverterFillComplexBuffer(
			self.info->converterRef,
			EZAudioFloatConverterCallback,
			&userData,
			&frames,
			self.info->floatAudioBufferList,
			packetDescriptions ?
				packetDescriptions :
				self.info->packetDescriptions
		);
        
        //
        // Copy the converted buffers into the float buffer array stored
        // in memory
        //
        for (int i = 0; i < self.info->floatAudioBufferList->mNumberBuffers; i++)
        {
			float *buffer = buffers[i];
			
            memcpy(
				buffer + userData.frameOffset,
				self.info->floatAudioBufferList->mBuffers[i].mData,
				self.info->floatAudioBufferList->mBuffers[i].mDataByteSize
			);
        }
        
        userData.frameOffset += frames;
        availableFrames -= frames;
    }
}

//------------------------------------------------------------------------------

@end
