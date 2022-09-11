//
//  EZOutput.m
//  EZAudio
//
//  Created by Syed Haris Ali on 12/2/13.
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

#import "EZOutput.h"
#import "EZAudioDevice.h"
#import "EZAudioFloatConverter.h"
#import "EZAudioUtilities.h"

#include <map>
#include <mutex>

//------------------------------------------------------------------------------
#pragma mark - Constants
//------------------------------------------------------------------------------

UInt32  const EZOutputMaximumFramesPerSlice = 4096;
Float64 const EZOutputDefaultSampleRate     = 44100.0f;

//------------------------------------------------------------------------------
#pragma mark - Data Structures
//------------------------------------------------------------------------------

typedef struct
{
    // stream format params
    AudioStreamBasicDescription clientFormat;
    
    // float converted data
//    float **inputData;
    float **outputData;
    
    // nodes
    EZAudioNodeInfo mixerNodeInfo;
    EZAudioNodeInfo outputNodeInfo;
    
    // audio graph
    AUGraph graph;
    Boolean graphUpdated;
} EZOutputInfo;

//------------------------------------------------------------------------------
#pragma mark - Callbacks (Declaration)
//------------------------------------------------------------------------------

OSStatus EZOutputConverterInputCallback(void                       *inRefCon,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp       *inTimeStamp,
                                        UInt32					    inBusNumber,
                                        UInt32					    inNumberFrames,
                                        AudioBufferList            *ioData);

//------------------------------------------------------------------------------

OSStatus EZOutputGraphRenderCallback(void                       *inRefCon,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp       *inTimeStamp,
                                     UInt32					     inBusNumber,
                                     UInt32                      inNumberFrames,
                                     AudioBufferList            *ioData);

//------------------------------------------------------------------------------
#pragma mark - EZOutput (Interface Extension)
//------------------------------------------------------------------------------

@interface EZOutput ()
//@property (nonatomic, strong) EZAudioFloatConverter *inputConverter;
@property (nonatomic, strong) EZAudioFloatConverter *outputConverter;
@property (nonatomic, assign) EZOutputInfo *info;
@end

//------------------------------------------------------------------------------
#pragma mark - EZOutput (Implementation)
//------------------------------------------------------------------------------

struct DataSourceNode {
	AudioStreamBasicDescription format;
	id<EZOutputDataSource> source;

    EZAudioNodeInfo converterNodeInfo;
    void *parent;
} ;
typedef std::map<EZBusID, DataSourceNode> DataSources;

@implementation EZOutput {

@public
	std::mutex mutex;
	DataSources dataSources;
}

//------------------------------------------------------------------------------
#pragma mark - Dealloc
//------------------------------------------------------------------------------

- (void)dealloc
{
//    if (self.inputConverter)
//    {
//        self.inputConverter = nil;
//        [EZAudioUtilities freeFloatBuffers:self.info->inputData
//                          numberOfChannels:self.info->clientFormat.mChannelsPerFrame];
//    }
    if (self.outputConverter)
    {
        self.outputConverter = nil;
        [EZAudioUtilities freeFloatBuffers:self.info->outputData
                          numberOfChannels:self.info->clientFormat.mChannelsPerFrame];
    }

    [EZAudioUtilities checkResult:AUGraphStop(self.info->graph)
                        operation:"Failed to stop graph"];
    [EZAudioUtilities checkResult:AUGraphClose(self.info->graph)
                        operation:"Failed to close graph"];
    [EZAudioUtilities checkResult:DisposeAUGraph(self.info->graph)
                        operation:"Failed to dispose of graph"];
    free(self.info);
}

//------------------------------------------------------------------------------
#pragma mark - Initialization
//------------------------------------------------------------------------------

- (instancetype) init
{
    self = [super init];
    if (self)
    {
        [self setup];
    }
    return self;
}

//------------------------------------------------------------------------------

- (instancetype)initWithDataSource:(id<EZOutputDataSource>)dataSource
                       inputFormat:(AudioStreamBasicDescription)inputFormat
{
    self = [self init];
    if (self)
    {
		[self addDataSource:dataSource withFormat:inputFormat];
    }
    return self;
}

//------------------------------------------------------------------------------
#pragma mark - Class Initializers
//------------------------------------------------------------------------------

+ (instancetype)output
{
    return [[self alloc] init];
}

//------------------------------------------------------------------------------

+ (instancetype)outputWithDataSource:(id<EZOutputDataSource>)dataSource
                         inputFormat:(AudioStreamBasicDescription)inputFormat
{
    return [[self alloc] initWithDataSource:dataSource
                                inputFormat:inputFormat];
}

//------------------------------------------------------------------------------
#pragma mark - Singleton
//------------------------------------------------------------------------------

+ (instancetype)sharedOutput
{
    static EZOutput *output;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        output = [[self alloc] init];
    });
    return output;
}

-(Float64)sampleRate
{
#if TARGET_OS_IPHONE
	AVAudioSession *audioSession = [AVAudioSession sharedInstance];
	return [audioSession sampleRate];
#elif TARGET_OS_MAC
	
	AudioObjectPropertyAddress nominal_sample_rate_address = {
		kAudioDevicePropertyNominalSampleRate,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMaster
	};
  
	Float64 nominal_sample_rate;
	UInt32 info_size = sizeof(nominal_sample_rate);
	AudioDeviceID deviceID = self.device.deviceID;

	[EZAudioUtilities checkResult:AudioObjectGetPropertyData(deviceID,
                                   &nominal_sample_rate_address,
                                   0,
                                   NULL,
                                   &info_size,
                                   &nominal_sample_rate)
            operation:"Couldn't get sample rate count"];

	return nominal_sample_rate;
#endif
}

//------------------------------------------------------------------------------
#pragma mark - Setup
//------------------------------------------------------------------------------

- (void) removeDataSource:(EZBusID)busID
{
	DataSourceNode &node = self->dataSources[busID];
	// ???
	
    [EZAudioUtilities checkResult:AUGraphRemoveNode(
		self.info->graph,
		node.converterNodeInfo.node)
		operation:"Failed to remove converter node to audio graph"];

	[EZAudioUtilities checkResult:AUGraphUpdate(self.info->graph, NULL)
		operation:"Failed to update render graph"];
		
	std::lock_guard<std::mutex> l(self->mutex);
	self->dataSources.erase(busID);
}

- (EZBusID) addDataSource:(id<EZOutputDataSource>)source withFormat:(AudioStreamBasicDescription)format
{
	EZBusID busID = 0;
	
	DataSourceNode *node_ = nullptr;
	{
		std::lock_guard<std::mutex> l(self->mutex);
		while (self->dataSources.find(busID) != self->dataSources.end())
			busID++;
			
		node_ = &self->dataSources[busID];
	}
		
	auto &node = *node_;
	node.format = format;
	node.source = source;
	node.parent = (__bridge void *)(self);
	
    //
    // Add converter node
    //
    AudioComponentDescription converterDescription;
    converterDescription.componentType = kAudioUnitType_FormatConverter;
    converterDescription.componentSubType = kAudioUnitSubType_AUConverter;
    converterDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    [EZAudioUtilities checkResult:AUGraphAddNode(self.info->graph,
                                                 &converterDescription,
                                                 &node.converterNodeInfo.node)
                        operation:"Failed to add converter node to audio graph"];

    //
    // Make node connections
    //
    OSStatus status = [self connectOutputOfSourceNode:node.converterNodeInfo.node
                                  sourceNodeOutputBus:0
                                    toDestinationNode:self.info->mixerNodeInfo.node
                              destinationNodeInputBus:busID
                                              inGraph:self.info->graph];
                                              
    [EZAudioUtilities checkResult:status
                        operation:"Failed to connect output of source node to destination node in graph"];


    //
    // Get the audio units
    //
    [EZAudioUtilities checkResult:AUGraphNodeInfo(self.info->graph,
                                                  node.converterNodeInfo.node,
                                                  &converterDescription,
                                                  &node.converterNodeInfo.audioUnit)
                        operation:"Failed to get converter audio unit"];

                        
                        
    [EZAudioUtilities checkResult:AudioUnitSetProperty(node.converterNodeInfo.audioUnit,
                                                       kAudioUnitProperty_StreamFormat,
                                                       kAudioUnitScope_Input,
                                                       0,
                                                       &node.format,
                                                       sizeof(node.format))
                        operation:"Failed to set input format on converter audio unit"];

	[self setClientFormat:self.info->clientFormat node:node];

    //
    // Add a node input callback for the converter node
    //
    AURenderCallbackStruct converterCallback;
    converterCallback.inputProc = EZOutputConverterInputCallback;
    converterCallback.inputProcRefCon = (void *)(&node);
    [EZAudioUtilities checkResult:AUGraphSetNodeInputCallback(self.info->graph,
                                                              node.converterNodeInfo.node,
                                                              0,
                                                              &converterCallback)
                        operation:"Failed to set render callback on converter node"];

//	[EZAudioUtilities checkResult:AUGraphUpdate(self.info->graph, &self.info->graphUpdated)
//		operation:"Failed to update render graph"];
	[EZAudioUtilities checkResult:AUGraphUpdate(self.info->graph, NULL)
		operation:"Failed to update render graph"];
	
	return busID;
}

- (void)setup
{
    //
    // Create structure to hold state data
    //
    self.info = (EZOutputInfo *)malloc(sizeof(EZOutputInfo));
    memset(self.info, 0, sizeof(EZOutputInfo));

    //
    // Use the default device
    //
	EZAudioDevice *currentOutputDevice = [EZAudioDevice currentOutputDevice];
	[self setDevice_:currentOutputDevice];
	
	//
	//
	//


    //
    // Setup the audio graph
    //
    [EZAudioUtilities checkResult:NewAUGraph(&self.info->graph)
                        operation:"Failed to create graph"];
    
    //
    // Add mixer node
    //
    AudioComponentDescription mixerDescription;
    mixerDescription.componentType = kAudioUnitType_Mixer;
#if TARGET_OS_IPHONE
    mixerDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer;
#elif TARGET_OS_MAC
    mixerDescription.componentSubType = kAudioUnitSubType_StereoMixer;
#endif
    mixerDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    [EZAudioUtilities checkResult:AUGraphAddNode(self.info->graph,
                                                 &mixerDescription,
                                                 &self.info->mixerNodeInfo.node)
                        operation:"Failed to add mixer node to audio graph"];
    
    //
    // Add output node
    //
    AudioComponentDescription outputDescription;
    outputDescription.componentType = kAudioUnitType_Output;
    outputDescription.componentSubType = [self outputAudioUnitSubType];
    outputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    [EZAudioUtilities checkResult:AUGraphAddNode(self.info->graph,
                                                 &outputDescription,
                                                 &self.info->outputNodeInfo.node)
                        operation:"Failed to add output node to audio graph"];
    
    //
    // Open the graph
    //
    [EZAudioUtilities checkResult:AUGraphOpen(self.info->graph)
                        operation:"Failed to open graph"];
    

    
    //
    // Connect mixer to output
    //
    [EZAudioUtilities checkResult:AUGraphConnectNodeInput(self.info->graph,
                                                          self.info->mixerNodeInfo.node,
                                                          0,
                                                          self.info->outputNodeInfo.node,
                                                          0)
                        operation:"Failed to connect mixer node to output node"];
    

    [EZAudioUtilities checkResult:AUGraphNodeInfo(self.info->graph,
                                                  self.info->mixerNodeInfo.node,
                                                  &mixerDescription,
                                                  &self.info->mixerNodeInfo.audioUnit)
                        operation:"Failed to get mixer audio unit"];
    [EZAudioUtilities checkResult:AUGraphNodeInfo(self.info->graph,
                                                  self.info->outputNodeInfo.node,
                                                  &outputDescription,
                                                  &self.info->outputNodeInfo.audioUnit)
                        operation:"Failed to get output audio unit"];
    

    
    //
    // Set stream formats
    //
    [self setClientFormat:[self clientFormatWithSampleRate:self.sampleRate]];
    [self onSetDevice];
    
    //
    // Initialize all the audio units in the graph
    //
    [EZAudioUtilities checkResult:AUGraphInitialize(self.info->graph)
                        operation:"Failed to initialize graph"];
    
    //
    // Add render callback
    //
    [EZAudioUtilities checkResult:AudioUnitAddRenderNotify(self.info->mixerNodeInfo.audioUnit,
                                                           EZOutputGraphRenderCallback,
                                                           (__bridge void *)(self))
                        operation:"Failed to add render callback"];
}

//------------------------------------------------------------------------------
#pragma mark - Actions
//------------------------------------------------------------------------------

- (void)startPlayback
{
    //
    // Start the AUGraph
    //
    [EZAudioUtilities checkResult:AUGraphStart(self.info->graph)
                        operation:"Failed to start graph"];
    
    //
    // Notify delegate
    //
    if ([self.delegate respondsToSelector:@selector(output:changedPlayingState:)])
    {
        [self.delegate output:self changedPlayingState:[self isPlaying]];
    }
}

//------------------------------------------------------------------------------

- (void)stopPlayback
{
    //
    // Stop the AUGraph
    //
    [EZAudioUtilities checkResult:AUGraphStop(self.info->graph)
                        operation:"Failed to stop graph"];
    
    //
    // Notify delegate
    //
    if ([self.delegate respondsToSelector:@selector(output:changedPlayingState:)])
    {
        [self.delegate output:self changedPlayingState:[self isPlaying]];
    }
}

//------------------------------------------------------------------------------
#pragma mark - Getters
//------------------------------------------------------------------------------

- (AudioStreamBasicDescription)clientFormat
{
    return self.info->clientFormat;
}

//------------------------------------------------------------------------------

- (BOOL)isPlaying
{
    Boolean isPlaying;
    [EZAudioUtilities checkResult:AUGraphIsRunning(self.info->graph,
                                                   &isPlaying)
                        operation:"Failed to check if graph is running"];
    return isPlaying;
}

//------------------------------------------------------------------------------

- (float)pan
{
    AudioUnitParameterID param;
#if TARGET_OS_IPHONE
    param = kMultiChannelMixerParam_Pan;
#elif TARGET_OS_MAC
    param = kStereoMixerParam_Pan;
#endif
    AudioUnitParameterValue pan;
    [EZAudioUtilities checkResult:AudioUnitGetParameter(self.info->mixerNodeInfo.audioUnit,
                                                        param,
                                                        kAudioUnitScope_Output,
                                                        0,
                                                        &pan) operation:"Failed to get pan from mixer unit"];
    return pan;
}

//------------------------------------------------------------------------------

- (float)volume
{
    AudioUnitParameterID param;
#if TARGET_OS_IPHONE
    param = kMultiChannelMixerParam_Volume;
#elif TARGET_OS_MAC
    param = kStereoMixerParam_Volume;
#endif
    AudioUnitParameterValue volume;
    [EZAudioUtilities checkResult:AudioUnitGetParameter(self.info->mixerNodeInfo.audioUnit,
                                                        param,
                                                        kAudioUnitScope_Output,
                                                        0,
                                                        &volume)
                        operation:"Failed to get volume from mixer unit"];
    return volume;
}

//------------------------------------------------------------------------------
#pragma mark - Setters
//------------------------------------------------------------------------------

- (void)setClientFormat:(AudioStreamBasicDescription)clientFormat node:(DataSourceNode &)node
{
	[EZAudioUtilities checkResult:AudioUnitSetProperty(node.converterNodeInfo.audioUnit,
													   kAudioUnitProperty_StreamFormat,
													   kAudioUnitScope_Output,
													   0,
													   &clientFormat,
													   sizeof(clientFormat))
					operation:"Failed to set output client format on converter audio unit"];
}

- (UInt32)maximumFramesPerSlice
{
    UInt32 maximumFramesPerSlice;
    UInt32 propSize = sizeof(maximumFramesPerSlice);
    [EZAudioUtilities checkResult:AudioUnitGetProperty(self.info->mixerNodeInfo.audioUnit,
                                                       kAudioUnitProperty_MaximumFramesPerSlice,
                                                       kAudioUnitScope_Global,
                                                       0,
                                                       &maximumFramesPerSlice,
                                                       &propSize)
                        operation:"Failed to get maximum number of frames per slice"];
    return maximumFramesPerSlice;
}

- (void)setClientFormat:(AudioStreamBasicDescription)clientFormat
{
    if (self.outputConverter)
    {
        self.outputConverter = nil;
        [EZAudioUtilities freeFloatBuffers:self.info->outputData
                          numberOfChannels:self.clientFormat.mChannelsPerFrame];
    }
    
    self.info->clientFormat = clientFormat;
    for (auto &dataSource_ : dataSources)
    {
		auto &node = dataSource_.second;
    
		[self setClientFormat:clientFormat node:node];
	}
	
    [EZAudioUtilities checkResult:AudioUnitSetProperty(self.info->mixerNodeInfo.audioUnit,
                                                       kAudioUnitProperty_StreamFormat,
                                                       kAudioUnitScope_Input,
                                                       0,
                                                       &self.info->clientFormat,
                                                       sizeof(self.info->clientFormat))
                        operation:"Failed to set input client format on mixer audio unit"];
    [EZAudioUtilities checkResult:AudioUnitSetProperty(self.info->mixerNodeInfo.audioUnit,
                                                       kAudioUnitProperty_StreamFormat,
                                                       kAudioUnitScope_Output,
                                                       0,
                                                       &self.info->clientFormat,
                                                       sizeof(self.info->clientFormat))
                        operation:"Failed to set output client format on mixer audio unit"];
    
    
    //
    // Set maximum frames per slice to 4096 to allow playback during
    // lock screen (iOS only?)
    //
    UInt32 maximumFramesPerSlice_ = EZOutputMaximumFramesPerSlice;
    [EZAudioUtilities checkResult:AudioUnitSetProperty(self.info->mixerNodeInfo.audioUnit,
                                                       kAudioUnitProperty_MaximumFramesPerSlice,
                                                       kAudioUnitScope_Global,
                                                       0,
                                                       &maximumFramesPerSlice_,
                                                       sizeof(maximumFramesPerSlice_))
                        operation:"Failed to set maximum frames per slice on mixer node"];
        
    auto maximumFramesPerSlice = [self maximumFramesPerSlice];
    self.outputConverter = [[EZAudioFloatConverter alloc] initWithInputFormat:clientFormat numberOfFrames:maximumFramesPerSlice];
    self.info->outputData = [EZAudioUtilities floatBuffersWithNumberOfFrames:maximumFramesPerSlice
                                                           numberOfChannels:clientFormat.mChannelsPerFrame];
}

//------------------------------------------------------------------------------

- (void)setDevice:(EZAudioDevice *)device
{
	[self setDevice_:device];
	[self onSetDevice];
}

- (void)setDevice_:(EZAudioDevice *)device
{
    // if the devices are equal then ignore
    if ([device isEqual:self.device])
    {
        return;
    }

    // store device
    _device = device;
    
#if TARGET_OS_IPHONE
    
    NSError *error;
    [[AVAudioSession sharedInstance] setOutputDataSource:device.dataSource error:&error];
    if (error)
    {
        NSLog(@"Error setting output device data source (%@), reason: %@",
              device.dataSource,
              error.localizedDescription);
    }
#endif
}

- (void)onSetDevice
{
#if TARGET_OS_IPHONE

#elif TARGET_OS_MAC
    UInt32 outputEnabled = self.device.outputChannelCount > 0;
    NSAssert(outputEnabled, @"Selected EZAudioDevice does not have any output channels");
    if ([self outputAudioUnitSubType] == kAudioUnitSubType_HALOutput)
    {
    [EZAudioUtilities checkResult:AudioUnitSetProperty(self.info->outputNodeInfo.audioUnit,
                                                       kAudioOutputUnitProperty_EnableIO,
                                                       kAudioUnitScope_Output,
                                                       0,
                                                       &outputEnabled,
                                                       sizeof(outputEnabled))
                        operation:"Failed to set flag on device output"];
    
    AudioDeviceID deviceId = self.device.deviceID;
    [EZAudioUtilities checkResult:AudioUnitSetProperty(self.info->outputNodeInfo.audioUnit,
                                                       kAudioOutputUnitProperty_CurrentDevice,
                                                       kAudioUnitScope_Global,
                                                       0,
                                                       &deviceId,
                                                       sizeof(AudioDeviceID))
                        operation:"Couldn't set default device on I/O unit"];
	}
#endif
    
    // notify delegate
    if ([self.delegate respondsToSelector:@selector(output:changedDevice:)])
    {
        [self.delegate output:self changedDevice:self.device];
    }
}

//------------------------------------------------------------------------------

- (void)setPan:(float)pan
{
    AudioUnitParameterID param;
#if TARGET_OS_IPHONE
    param = kMultiChannelMixerParam_Pan;
#elif TARGET_OS_MAC
    param = kStereoMixerParam_Pan;
#endif
    [EZAudioUtilities checkResult:AudioUnitSetParameter(self.info->mixerNodeInfo.audioUnit,
                                                        param,
                                                        kAudioUnitScope_Output,
                                                        0,
                                                        pan,
                                                        0)
                        operation:"Failed to set volume on mixer unit"];
}

//------------------------------------------------------------------------------

- (void)setVolume:(float)volume
{
    AudioUnitParameterID param;
#if TARGET_OS_IPHONE
    param = kMultiChannelMixerParam_Volume;
#elif TARGET_OS_MAC
    param = kStereoMixerParam_Volume;
#endif
    [EZAudioUtilities checkResult:AudioUnitSetParameter(self.info->mixerNodeInfo.audioUnit,
                                                        param,
                                                        kAudioUnitScope_Output,
                                                        0,
                                                        volume,
                                                        0)
                        operation:"Failed to set volume on mixer unit"];
}

//------------------------------------------------------------------------------
#pragma mark - Core Audio Properties
//------------------------------------------------------------------------------

- (AUGraph)graph
{
    return self.info->graph;
}

//------------------------------------------------------------------------------

- (AudioUnit)mixerAudioUnit
{
    return self.info->mixerNodeInfo.audioUnit;
}

//------------------------------------------------------------------------------

- (AudioUnit)outputAudioUnit
{
    return self.info->outputNodeInfo.audioUnit;
}

//------------------------------------------------------------------------------
#pragma mark - Subclass
//------------------------------------------------------------------------------

- (OSStatus)connectOutputOfSourceNode:(AUNode)sourceNode
                  sourceNodeOutputBus:(UInt32)sourceNodeOutputBus
                    toDestinationNode:(AUNode)destinationNode
              destinationNodeInputBus:(UInt32)destinationNodeInputBus
                              inGraph:(AUGraph)graph
{
    //
    // Default implementation is to just connect the source to destination
    //
    [EZAudioUtilities checkResult:AUGraphConnectNodeInput(graph,
                                                          sourceNode,
                                                          sourceNodeOutputBus,
                                                          destinationNode,
                                                          destinationNodeInputBus)
                        operation:"Failed to connect converter node to mixer node"];
    return noErr;
}

//------------------------------------------------------------------------------

- (AudioStreamBasicDescription)clientFormatWithSampleRate:(Float64)sampleRate
{
    return [EZAudioUtilities stereoFloatNonInterleavedFormatWithSampleRate:sampleRate];
}


//------------------------------------------------------------------------------

- (OSType)outputAudioUnitSubType
{
//	return kAudioUnitSubType_VoiceProcessingIO;

#if TARGET_OS_IPHONE
    return kAudioUnitSubType_RemoteIO;
#elif TARGET_OS_MAC
    return kAudioUnitSubType_HALOutput;
#endif
}

//------------------------------------------------------------------------------

@end

//------------------------------------------------------------------------------
#pragma mark - Callbacks (Implementation)
//------------------------------------------------------------------------------

OSStatus EZOutputConverterInputCallback(void                       *inRefCon,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp       *inTimeStamp,
                                        UInt32					    inBusNumber,
                                        UInt32					    inNumberFrames,
                                        AudioBufferList            *ioData)
{
	DataSourceNode *dataSourceNode = (DataSourceNode *)inRefCon;
    EZOutput *output = (__bridge EZOutput *)dataSourceNode->parent;
    
    //
    // Try to ask the data source for audio data to fill out the output's
    // buffer list
    //
    
	id<EZOutputDataSource> dataSource = dataSourceNode->source;

	if (dataSource)
	{
		if ([dataSource respondsToSelector:@selector(output:shouldFillAudioBufferList:withNumberOfFrames:timestamp:)])
		{
			return [dataSource output:output
				   shouldFillAudioBufferList:ioData
						  withNumberOfFrames:inNumberFrames
								   timestamp:inTimeStamp];
		}
	}

	//
	// Silence if there is nothing to output
	//
	for (int i = 0; i < ioData->mNumberBuffers; i++)
	{
		memset(ioData->mBuffers[i].mData,
			   0,
			   ioData->mBuffers[i].mDataByteSize);
	}
    return noErr;
}

//------------------------------------------------------------------------------

OSStatus EZOutputGraphRenderCallback(void                       *inRefCon,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp       *inTimeStamp,
                                     UInt32					     inBusNumber,
                                     UInt32                      inNumberFrames,
                                     AudioBufferList            *ioData)
{
	if (ioData->mBuffers[0].mData == NULL)
	{
		return noErr;
	}

    EZOutput *output = (__bridge EZOutput *)inRefCon;

    //
    // provide the audio received delegate callback
    //
    if (*ioActionFlags & kAudioUnitRenderAction_PostRender)
    {
        if ([output.delegate respondsToSelector:@selector(output:playedAudio:withBufferSize:withNumberOfChannels:)])
        {
            UInt32 frames = ioData->mBuffers[0].mDataByteSize / output.info->clientFormat.mBytesPerFrame;
            
            [output.outputConverter convertDataFromAudioBufferList:ioData
                                               withNumberOfFrames:frames
                                                   toFloatBuffers:output.info->outputData];
            [output.delegate output:output
                        playedAudio:output.info->outputData
                     withBufferSize:inNumberFrames
               withNumberOfChannels:output.info->clientFormat.mChannelsPerFrame];
        }
    }
    return noErr;
}
