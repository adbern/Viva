//
//  EQCoreAudioController.m
//  Viva
//
//  Created by Daniel Kennett on 03/04/2012.
//  For license information, see LICENSE.markdown
//

#import "EQCoreAudioController.h"
#import "Constants.h"
#import <AudioToolbox/AudioToolbox.h>

@interface EQCoreAudioController ()

-(void)applyBandsToEQ:(EQPreset *)preset;

@end

@implementation EQCoreAudioController {
	AUNode eqNode;
	AudioUnit eqUnit;
}

-(id)init {
	
	self = [super init];
	
	if (self) {
		
		[self addObserver:self forKeyPath:@"eqPreset" options:0 context:nil];
		
		EQPresetController *eqController = [EQPresetController sharedInstance];
		
		for (EQPreset *preset in [[[eqController.builtInPresets
									arrayByAddingObjectsFromArray:eqController.customPresets]
								   arrayByAddingObject:eqController.blankPreset]
								  arrayByAddingObject:eqController.unnamedCustomPreset]) {
			if ([preset.name isEqualToString:[[NSUserDefaults standardUserDefaults] valueForKey:kCurrentEQPresetNameUserDefaultsKey]]) {
				self.eqPreset = preset;
				break;
			}
		}
	}
	
	return self;
}

-(void)dealloc {	
	[self removeObserver:self forKeyPath:@"eqPreset"];
}

@synthesize eqPreset;

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"eqPreset"]) {
        [[NSUserDefaults standardUserDefaults] setValue:self.eqPreset.name
												 forKey:kCurrentEQPresetNameUserDefaultsKey];
		
		[self applyBandsToEQ:self.eqPreset];
		
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

-(void)applyBandsToEQ:(EQPreset *)preset {
	
	if (eqUnit == NULL) return;
	
	AudioUnitSetParameter(eqUnit, 0, kAudioUnitScope_Global, 0, (Float32)preset.band1, 0);
	AudioUnitSetParameter(eqUnit, 1, kAudioUnitScope_Global, 0, (Float32)preset.band2, 0);
	AudioUnitSetParameter(eqUnit, 2, kAudioUnitScope_Global, 0, (Float32)preset.band3, 0);
	AudioUnitSetParameter(eqUnit, 3, kAudioUnitScope_Global, 0, (Float32)preset.band4, 0);
	AudioUnitSetParameter(eqUnit, 4, kAudioUnitScope_Global, 0, (Float32)preset.band5, 0);
	AudioUnitSetParameter(eqUnit, 5, kAudioUnitScope_Global, 0, (Float32)preset.band6, 0);
	AudioUnitSetParameter(eqUnit, 6, kAudioUnitScope_Global, 0, (Float32)preset.band7, 0);
	AudioUnitSetParameter(eqUnit, 7, kAudioUnitScope_Global, 0, (Float32)preset.band8, 0);
	AudioUnitSetParameter(eqUnit, 8, kAudioUnitScope_Global, 0, (Float32)preset.band9, 0);
	AudioUnitSetParameter(eqUnit, 9, kAudioUnitScope_Global, 0, (Float32)preset.band10, 0);
}

#pragma mark - Setting up the EQ

-(BOOL)connectOutputBus:(UInt32)sourceOutputBusNumber ofNode:(AUNode)sourceNode toInputBus:(UInt32)destinationInputBusNumber ofNode:(AUNode)destinationNode inGraph:(AUGraph)graph error:(NSError **)error {
	
	// Override this method to connect the source node to the destination node via an EQ node.
	
	// A description for the EQ Device
	AudioComponentDescription eqDescription;
	eqDescription.componentType = kAudioUnitType_Effect;
	eqDescription.componentSubType = kAudioUnitSubType_GraphicEQ;
	eqDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	eqDescription.componentFlags = 0;
    eqDescription.componentFlagsMask = 0;
	
	// Add the EQ node to the AUGraph
	OSStatus status = AUGraphAddNode(graph, &eqDescription, &eqNode);
	if (status != noErr) {
        NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Couldn't add EQ node");
		return NO;
    }
	
	// Get the EQ Audio Unit from the node so we can set bands directly later
	status = AUGraphNodeInfo(graph, eqNode, NULL, &eqUnit);
	if (status != noErr) {
        NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Couldn't get EQ unit");
        return NO;
    }
	
	// Init the EQ
	status = AudioUnitInitialize(eqUnit);
	if (status != noErr) {
        NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Couldn't init EQ!");
        return NO;
    }
	
	// Set EQ to 10-band
	status = AudioUnitSetParameter(eqUnit, 10000, kAudioUnitScope_Global, 0, 0.0, 0);
	if (status != noErr) {
        NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Couldn't set EQ parameter");
        return NO;
    }
	
	// Connect the output of the source node to the input of the EQ node
	status = AUGraphConnectNodeInput(graph, sourceNode, sourceOutputBusNumber, eqNode, 0);
	if (status != noErr) {
        NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Couldn't connect converter to eq");
        return NO;
    }
	
	// Connect the output of the EQ node to the input of the destination node, thus completing the chain.
	status = AUGraphConnectNodeInput(graph, eqNode, 0, destinationNode, destinationInputBusNumber);
	if (status != noErr) {
        NSLog(@"[%@ %@]: %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), @"Couldn't connect eq to output");
        return NO;
    }
	
	[self applyBandsToEQ:self.eqPreset];
	
	return YES;
}

-(void)disposeOfCustomNodesInGraph:(AUGraph)graph {
	
	// Shut down our unit.
	AudioUnitUninitialize(eqUnit);
	eqUnit = NULL;
	
	// Remove the unit's node from the graph.
	AUGraphRemoveNode(graph, eqNode);
	eqNode = 0;
}

@end
