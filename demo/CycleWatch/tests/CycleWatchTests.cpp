#include "CycleWatch.h"

#include <iostream>

// MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION
// 日本語: executable は要求された三回連続の動作を決定的に検証します。
namespace {

int failures = 0;

void ExpectStatus(const char* caseName, team_bob_demo::CycleStatus actual, team_bob_demo::CycleStatus expected) {
    if (actual != expected) {
        std::cerr << "FAILED: " << caseName << std::endl;
        ++failures;
    }
}

void TestBoundary() {
    // BOUNDARY_7999_8000
    team_bob_demo::CycleWatch watch;
    ExpectStatus("7999 is Normal", watch.Observe("Customer-A", false, 7999U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("first 8000 is Normal", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
}

void TestThirdConsecutive() {
    // THIRD_CONSECUTIVE
    team_bob_demo::CycleWatch watch;
    ExpectStatus("overrun one", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("overrun two", watch.Observe("Customer-A", false, 9000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("overrun three", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Warning);
}

void TestImmediateRecovery() {
    // IMMEDIATE_RECOVERY
    team_bob_demo::CycleWatch watch;
    ExpectStatus("recovery setup one", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("recovery setup two", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("warning reached", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Warning);
    ExpectStatus("7999 recovers", watch.Observe("Customer-A", false, 7999U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("counter reset", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
}

void TestWarmupReset() {
    // WARMUP_RESET
    team_bob_demo::CycleWatch watch;
    ExpectStatus("before warm-up one", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("before warm-up two", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("warm-up suppresses", watch.Observe("Customer-A", true, 9000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("after reset one", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("after reset two", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("after reset three", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Warning);
}

void TestCustomerScope() {
    // CUSTOMER_A_ONLY
    team_bob_demo::CycleWatch watch;
    ExpectStatus("Customer-B one", watch.Observe("Customer-B", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("Customer-B two", watch.Observe("Customer-B", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("Customer-B three", watch.Observe("Customer-B", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("Customer-A one", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("Customer-A two", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Normal);
    ExpectStatus("Customer-A three", watch.Observe("Customer-A", false, 8000U), team_bob_demo::CycleStatus::Warning);
}

}  // namespace

int main() {
    std::cout << "MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION" << std::endl;
    TestBoundary();
    TestThirdConsecutive();
    TestImmediateRecovery();
    TestWarmupReset();
    TestCustomerScope();
    return failures == 0 ? 0 : 1;
}
