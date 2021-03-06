//
//  AlbumViewController.h
//  Viva
//
//  Created by Daniel Kennett on 4/24/11.
//  For license information, see LICENSE.markdown
//

#import <Cocoa/Cocoa.h>
#import "VivaSortableTrackListController.h"
#import <CocoaLibSpotify/CocoaLibSpotify.h>
#import "SPBackgroundColorView.h"
#import "VivaLinkTextField.h"
#import "VivaDraggableItemImageView.h"

@interface AlbumViewController : VivaSortableTrackListController {
@private
    SPAlbumBrowse *albumBrowse;
}

@property (weak) IBOutlet SPBackgroundColorView *backgroundColorView;
@property (weak) IBOutlet SPBackgroundColorView *leftColumnColorView;
@property (weak) IBOutlet VivaDraggableItemImageView *albumCoverView;
@property (weak) IBOutlet VivaLinkTextField *artistView;

@property (nonatomic, readonly, strong) SPAlbumBrowse *albumBrowse;

@end
