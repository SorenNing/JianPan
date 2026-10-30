// UIKBSplitImageView.h — iOS 17.2 (from headers.82flex.com, UIKitCore)
#import <UIKit/UIView.h>

@interface UIKBSplitImageView : UIView {
    BOOL _canStretchAsFullWidth;
    NSString *_currentFilterType;
    UIImageView *_fullView;
    NSLayoutConstraint *_leftWidthConstraint;
    NSLayoutConstraint *_rightWidthConstraint;
    NSArray *_splitConstraints;
    UIImageView *_splitLeft;
    UIImageView *_splitRight;
}
@property (retain, nonatomic) NSString *filterType;
- (BOOL)_shouldInheritScreenScaleAsContentScaleFactor;
- (void)clearImages;
- (id)filterType;
- (id)initWithFrame:(CGRect)frame canStretchAsFullWidth:(BOOL)width;
- (void)insertSubviewAtBottom:(id)bottom;
- (void)prepareForDisplay:(BOOL)display;
- (void)setContentsMultiplyColor:(id)color;
- (void)setFilterType:(id)type;
- (void)setImage:(id)image cachedWidth:(double)width keyplane:(id)keyplane;
- (void)setImage:(id)image splitLeft:(id)left splitRight:(id)right keyplane:(id)keyplane;
@end
