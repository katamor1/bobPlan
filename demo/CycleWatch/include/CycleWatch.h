#ifndef TEAM_BOB_DEMO_CYCLEWATCH_H
#define TEAM_BOB_DEMO_CYCLEWATCH_H

// MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION
// 日本語: 状態と連続回数は header が所有し、修復時に class layout を変更しません。
namespace team_bob_demo {

enum class CycleStatus {
    Normal = 0,
    Warning = 1
};

class CycleWatch {
public:
    CycleWatch();
    CycleStatus Observe(const char* customer, bool warmingUp, unsigned int cycleTimeUs);
    CycleStatus status() const;

private:
    unsigned int consecutiveOverruns_;
    CycleStatus status_;
};

}  // namespace team_bob_demo

#endif
