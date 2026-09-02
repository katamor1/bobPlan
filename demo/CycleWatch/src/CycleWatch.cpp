#include "CycleWatch.h"

#include <cstring>

// MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION
// 日本語: fault block は adapter qualification 専用で、通常 build では定義しません。
// TEAM_BOB_DEMO_FAULT_BEGIN
#if defined(TEAM_BOB_DEMO_FAULT)
#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")
#endif
// TEAM_BOB_DEMO_FAULT_END

namespace team_bob_demo {
namespace {

static const unsigned int kCycleOverrunThresholdUs = 8000U;

}  // namespace

CycleWatch::CycleWatch()
    : consecutiveOverruns_(0U), status_(CycleStatus::Normal) {
}

CycleStatus CycleWatch::Observe(const char* customer, bool warmingUp, unsigned int cycleTimeUs) {
    if (warmingUp) {
        consecutiveOverruns_ = 0U;
        status_ = CycleStatus::Normal;
        return status_;
    }

    if (customer == 0 || std::strcmp(customer, "Customer-A") != 0) {
        consecutiveOverruns_ = 0U;
        status_ = CycleStatus::Normal;
        return status_;
    }

    if (cycleTimeUs < kCycleOverrunThresholdUs) {
        consecutiveOverruns_ = 0U;
        status_ = CycleStatus::Normal;
        return status_;
    }

    ++consecutiveOverruns_;

    // TEAM_BOB_DEMO_REPAIR_POINT: 日本語: Warning は本来 3 回連続した時だけです。
    if (consecutiveOverruns_ >= 1U) {
        status_ = CycleStatus::Warning;
    } else {
        status_ = CycleStatus::Normal;
    }
    return status_;
}

CycleStatus CycleWatch::status() const {
    return status_;
}

}  // namespace team_bob_demo
