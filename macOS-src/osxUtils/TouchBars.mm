//
//  TouchBars.m
//  xLights
//

#include "TouchBars.h"

#import <Foundation/Foundation.h>
#include <Cocoa/Cocoa.h>
#include <wx/window.h>
#include <wx/panel.h>


#if __has_include(<AppKit/NSTouchBar.h>)


extern WXImage wxOSXGetImageFromBundle(const wxBitmapBundle& bundle);


@interface XLTouchBarViewController : NSViewController
@end

@interface XLTouchBarViewController () <NSTouchBarDelegate>
@property wxWindow *window;
@property xlTouchBar *xltouchBar;
@end


@interface ButtonPasser : NSObject
@property ButtonTouchBarItem *button;
@end

@implementation ButtonPasser
- (IBAction)buttonClicked:(id)sender
{
    _button->Clicked();
}
@end

@interface SegmentPasser : NSObject
@property GroupTouchBarItem *item;
@end

@implementation SegmentPasser
- (IBAction)buttonClicked:(id)sender
{
    int clickedSegment = [sender selectedSegment];
    _item->GetItems()[clickedSegment]->Clicked();
}
@end


@interface ColorPickerPasser : NSObject
@property ColorPickerItem *button;
@property (assign) NSColorPickerTouchBarItem *item;
@end

@implementation ColorPickerPasser
- (IBAction)buttonClicked:(id)sender
{
    NSColor *c = [_item color];
    wxColor xlc(c);
    _button->GetCallback()(xlc);
}
@end

@interface SliderPasser : NSObject
@property SliderItem *button;
@property (assign) NSSliderTouchBarItem *item;
@end

@implementation SliderPasser
- (IBAction)sliderChanged:(id)sender
{
    int i = _item.slider.intValue;
    _button->GetCallback()(i);
}
@end



class TouchBarItemData {
public:
    SliderPasser* sliderPasser = nullptr;
    ColorPickerPasser* colorPasser = nullptr;
    SegmentPasser* segmentPasser = nullptr;


    ButtonPasser* buttonPasser = nullptr;
    NSButton* button = nullptr;
};



@implementation XLTouchBarViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Note: If you ever want to show the NSTouchBar instance within this view controller do this:
    //if (self.view != nil) {
    //    [self.view.window makeFirstResponder:self.view];
    //}
}


- (void)invalidateTouchBar
{
    // We need to set the first responder status when one of our buttons was clicked.
    if (self.view != nil) {
        [self.view.window makeFirstResponder:self.view];
    }
    
    // Set to nil so makeTouchBar can be called again to re-create our NSTouchBarItem instances.
    self.touchBar = nil;
}

- (NSTouchBar *)makeTouchBar
{
    if (_xltouchBar != nullptr) {
        NSTouchBar *bar = [[NSTouchBar alloc] init];
        bar.delegate = self;
        
        std::string s = "org.xlights.TouchBar." + _window->GetName().ToStdString() + "." + _xltouchBar->GetName();
        NSString *n = [NSString stringWithCString:s.c_str()
                                         encoding:[NSString defaultCStringEncoding]];
        bar.customizationIdentifier = n;
        
        for (auto it = _xltouchBar->GetItems().begin(); it != _xltouchBar->GetItems().end(); it++) {
            std::string itemName = s + "." + (*it)->GetName();
            n = [NSString stringWithCString:itemName.c_str()
                                   encoding:[NSString defaultCStringEncoding]];
            bar.defaultItemIdentifiers = [bar.defaultItemIdentifiers arrayByAddingObject:n];
        }
        for (auto it = _xltouchBar->GetDefaultItems().begin(); it != _xltouchBar->GetDefaultItems().end(); it++) {
            std::string itemName = s + "." + (*it)->GetName();
            n = [NSString stringWithCString:itemName.c_str()
                                   encoding:[NSString defaultCStringEncoding]];
            bar.customizationAllowedItemIdentifiers = [bar.customizationAllowedItemIdentifiers arrayByAddingObject:n];
        }
        return bar;
    }
    return nil;
}

- (nullable NSTouchBarItem *) createChildItem:(NSTouchBarItemIdentifier)identifier
                                         item:(TouchBarItem *)it
{
    ButtonTouchBarItem *item = dynamic_cast<ButtonTouchBarItem*>(it);
    if (item != nullptr) {
        std::string label = item->GetLabel();
        if (label == "") {
            label = item->GetName();
        }
        NSCustomTouchBarItem *ret = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        NSString *nm = [NSString stringWithCString:label.c_str()
                                          encoding:[NSString defaultCStringEncoding]];
        
        ButtonPasser *bp = [ButtonPasser alloc];
        bp.button = item;
        
        NSButton* theButton;
        if (item->GetBitmap().IsOk()) {
            theButton = [NSButton buttonWithImage:wxOSXGetImageFromBundle(item->GetBitmap()) target:bp action:@selector(buttonClicked:)];
            [theButton setImagePosition:NSImageOnly];
            [theButton setBordered:NO];
        } else if (item->GetName().substr(0, 10) == "NSTouchBar") {
            //NSString *in2 = NSImageNameTouchBarColorPickerFill;
            NSString *in = [NSString stringWithCString:item->GetName().c_str()
                                              encoding:[NSString defaultCStringEncoding]];
            NSImage *image = [NSImage imageNamed:in];
            theButton = [NSButton buttonWithImage:image target:bp action:@selector(buttonClicked:)];
            [theButton setImagePosition:NSImageOnly];
            [theButton setBordered:NO];
        } else {
            theButton = [NSButton buttonWithTitle:nm target:bp action:@selector(buttonClicked:)];
        }
        ret.view = theButton;
        ret.customizationLabel = nm;
        
        if (item->GetBackgroundColor().Alpha() > 0) {
            theButton.bezelColor = item->GetBackgroundColor().OSXGetNSColor();
        }
        it->GetData()->buttonPasser = bp;
        it->GetData()->button = theButton;
        return ret;
    }
    
    wxControlTouchBarItem *ctbi = dynamic_cast<wxControlTouchBarItem*>(it);
    if (ctbi != nullptr) {
        NSCustomTouchBarItem *ret = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        
        NSString *nm = [NSString stringWithCString:ctbi->GetName().c_str()
                                          encoding:[NSString defaultCStringEncoding]];
        
        
        
        ret.view = (NSView*)ctbi->GetControl()->GetHandle();;
        ret.customizationLabel = nm;
        return ret;
    }
    
    ColorPickerItem *cpi =  dynamic_cast<ColorPickerItem*>(it);
    if (cpi != nullptr) {
        NSColorPickerTouchBarItem *ret;
        if (cpi->GetBitmap().IsOk()) {
            ret = [NSColorPickerTouchBarItem colorPickerWithIdentifier:identifier buttonImage:cpi->GetBitmap().GetNSImage()];
        } else {
            ret = [NSColorPickerTouchBarItem colorPickerWithIdentifier:identifier];
        }
        ret.showsAlpha = false;
        
        NSString *nm = [NSString stringWithCString:cpi->GetName().c_str()
                                          encoding:[NSString defaultCStringEncoding]];
        ColorPickerPasser *bp = [ColorPickerPasser alloc];
        bp.button = cpi;
        bp.item = ret;
        
        [ret setTarget:bp];
        [ret setAction:@selector(buttonClicked:)];
        ret.customizationLabel = nm;
        ret.color = cpi->GetColor().OSXGetNSColor();
        [ret setColor:cpi->GetColor().OSXGetNSColor()];

        it->GetData()->colorPasser = bp;

        return ret;
    }
    
    SliderItem *slider = dynamic_cast<SliderItem*>(it);
    if (slider != nullptr) {
        NSSliderTouchBarItem *ret = [[NSSliderTouchBarItem alloc] initWithIdentifier:identifier];
        NSString *nm = [NSString stringWithCString:slider->GetName().c_str()
                                          encoding:[NSString defaultCStringEncoding]];
        ret.customizationLabel = nm;
        ret.slider.minValue = slider->GetMin();
        ret.slider.maxValue = slider->GetMax();
        ret.slider.intValue = slider->GetValue();
        
        SliderPasser *bp = [SliderPasser alloc];
        bp.button = slider;
        bp.item = ret;
        [ret setTarget:bp];
        [ret setAction:@selector(sliderChanged:)];

        it->GetData()->sliderPasser = bp;

        return ret;
    }
    
    GroupTouchBarItem *group = dynamic_cast<GroupTouchBarItem*>(it);
    if (group != nullptr) {
        NSMutableArray<NSImage *> *bi = [NSMutableArray arrayWithCapacity:group->GetItems().size()];
        //fill
        for (auto it2 : group->GetItems()) {
            [bi addObject:(wxOSXGetImageFromBundle(it2->GetBitmap()))];
        }
        
        SegmentPasser *bp = [SegmentPasser alloc];
        bp.item = group;

        NSSegmentedControl *segmentedControl = [NSSegmentedControl segmentedControlWithImages: bi
                                                                trackingMode: NSSegmentSwitchTrackingMomentary
                                                                target: bp
                                                                action: @selector(buttonClicked:)];
        
        for (int x = 0; x < group->GetItems().size(); x++) {
            [segmentedControl setWidth:24 forSegment: x];
        }
        NSCustomTouchBarItem *ret = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        NSString *nm = [NSString stringWithCString:group->GetName().c_str()
                                          encoding:[NSString defaultCStringEncoding]];
        
        
        it->GetData()->segmentPasser = bp;

        ret.view = segmentedControl;
        ret.customizationLabel = nm;
        return ret;
    }
    return nullptr;
}


- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    std::string s = "org.xlights.TouchBar." + _window->GetName().ToStdString() + "." + _xltouchBar->GetName();

    for (auto it = _xltouchBar->GetItems().begin(); it != _xltouchBar->GetItems().end(); it++) {
        std::string itemName = s + "." + (*it)->GetName();
        NSString *n = [NSString stringWithCString:itemName.c_str()
                               encoding:[NSString defaultCStringEncoding]];
        
        if ([identifier isEqualToString:n]) {
            return [self createChildItem:identifier item:(*it)];
        }
    }
    return nil;
}
@end


class TouchBarContollerData {
public:
    TouchBarContollerData(XLTouchBarViewController *c) : controller(c) {}

    XLTouchBarViewController *controller;
};


TouchBarContollerData *initializeTouchBarSupport(wxWindow *w) {
    Class cls = NSClassFromString(@"NSTouchBar");
    if (cls == nil) {
        return nullptr;
    }
    
    NSApplication *app = [NSApplication sharedApplication];
    app.automaticCustomizeTouchBarMenuItemEnabled = true;

    
    XLTouchBarViewController *cont = [[XLTouchBarViewController alloc] init];
    cont.window = w;
    NSView *view = (NSView*)w->GetHandle();
    cont.view = view;
    
    [cont viewDidLoad];
    return new TouchBarContollerData(cont);
}
void setActiveTouchbar(TouchBarContollerData *cdata, xlTouchBar *tb) {
    if (cdata != nil) {
        XLTouchBarViewController *cont = cdata->controller;
        cont.xltouchBar = tb;
        cont.view = (NSView*)cont.window->GetHandle();
        [cont invalidateTouchBar];
    }
}

#else
class TouchBarContollerData {
public:
};
TouchBarContollerData *initializeTouchBarSuppor(wxWindow *w) { return nullptr; }
void setActiveTouchbar(TouchBarContollerData *controller, xlTouchBar *tb) {}

#endif

xlTouchBarSupport::xlTouchBarSupport() : window(nullptr), parent(nullptr), controllerData(nullptr) {
}
xlTouchBarSupport::~xlTouchBarSupport() {
    if (controllerData) {
        delete controllerData;
    }
}
void xlTouchBarSupport::Init(wxWindow *w) {
    controllerData = initializeTouchBarSupport(w);
    if (controllerData) {
        parent = new wxPanel(w->GetParent());
        parent->Hide();
    }
}
void xlTouchBarSupport::SetActive(xlTouchBar *tb) {
    setActiveTouchbar(controllerData, tb);
    currentBar = tb;
}


TouchBarItem::~TouchBarItem() {
    if (data) {
        delete data;
    }
}
TouchBarItemData *TouchBarItem::GetData() {
    if (!data) {
        data = new TouchBarItemData();
    }
    return data;
}


wxControlTouchBarItem::wxControlTouchBarItem(wxWindow *c) : TouchBarItem(c->GetName().ToStdString()), control(c) {

}
GroupTouchBarItem::~GroupTouchBarItem() {
    for (int x = 0; x < items.size(); x++) {
        delete items[x];
    }
    items.clear();
}

xlTouchBar::xlTouchBar(xlTouchBarSupport &s) : support(s) {
}
xlTouchBar::xlTouchBar(xlTouchBarSupport &s, std::vector<TouchBarItem*> &i) : support(s), items(std::move(i)) {
}
xlTouchBar::~xlTouchBar() {
    for (int x = 0; x < items.size(); x++) {
        delete items[x];
    }
    items.clear();
}


EffectGridTouchBar::EffectGridTouchBar(xlTouchBarSupport &support, std::vector<TouchBarItem*> &i) : xlTouchBar(support, i) {
}
EffectGridTouchBar::~EffectGridTouchBar() {
}


void ColorPickerItem::SetColor(const wxBitmap &b, wxColor &c) {
    bmp = b;
    color = c;
}

void SliderItem::SetValue(int i) {
    value = i;
}


ColorPanelTouchBar::ColorPanelTouchBar(ColorChangedFunction f,
                                       SliderItemChangedFunction spark,
                                       xlTouchBarSupport &support)
    : xlTouchBar(support), colorCallback(f), sparkCallback(spark), inCallback(false)
{
    xlTouchBarSupport *sp = &support;
    ButtonTouchBarItem *doneButton = new ButtonTouchBarItem([sp, this]() {
        sp->SetActive(lastBar);
    }, "Done", "Done");
    doneButton->SetBackgroundColor(*wxBLUE);
    items.push_back(doneButton);

    for (char x = '1'; x <= '8'; x++) {
        std::string name = "Color ";
        name += x;
        items.push_back(new ColorPickerItem([this, x](wxColor c) {
            this->inCallback = true;
            this->colorCallback(x - '1', c);
            this->inCallback = false;
        }, name));
    }

    items.push_back(new SliderItem([this](int i) {
        this->inCallback = true;
        this->sparkCallback(i);
        this->inCallback = false;
    }, "Sparkles", 0, 200));
}
ColorPanelTouchBar::~ColorPanelTouchBar() {
}
void ColorPanelTouchBar::SetActive() {
    lastBar = support.GetCurrentBar();
    support.SetActive(this);
}
void ColorPanelTouchBar::SetSparkles(int v) {
    if (inCallback) {
        return;
    }
    SliderItem *item = (SliderItem*)items[9];
    item->SetValue(v);
    if (support.IsActive(this)) {
        support.SetActive(this);
    }
}

void ColorPanelTouchBar::SetColor(int idx, const wxBitmap &bmp, wxColor &c) {
    if (inCallback) {
        return;
    }
    ColorPickerItem *item = (ColorPickerItem*)items[idx + 1];  //count for the Done button
    item->SetColor(bmp, c);
    if (support.IsActive(this)) {
        support.SetActive(this);
    }
}
