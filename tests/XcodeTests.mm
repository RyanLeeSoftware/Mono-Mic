#import <XCTest/XCTest.h>

int MonoMicLatencyTestsMain();
int MonoMicPipelineTestsMain();
int MonoMicAudioControlsTestsMain();
int MonoMicSettingsTestsMain();
extern "C" int MonoMicDriverTestsMain(void);

@interface MonoMicTests : XCTestCase
@end

@implementation MonoMicTests
- (void)testLatency { XCTAssertEqual(MonoMicLatencyTestsMain(), 0); }
- (void)testPipeline { XCTAssertEqual(MonoMicPipelineTestsMain(), 0); }
- (void)testAudioControls { XCTAssertEqual(MonoMicAudioControlsTestsMain(), 0); }
- (void)testSettings { XCTAssertEqual(MonoMicSettingsTestsMain(), 0); }
- (void)testDriver { XCTAssertEqual(MonoMicDriverTestsMain(), 0); }
@end
