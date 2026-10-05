// Synthetic numeric-stack regression only; no PDF documents are opened.
#include "core/fpdfapi/page/cpdf_psengine.h"

#include <cstdio>
#include <vector>

namespace {
bool Check(const char* name, const std::vector<float>& input, int n, int j,
           const std::vector<float>& expected) {
  CPDF_PSEngine engine;
  for (float value : input) {
    engine.Push(value);
  }
  engine.Push(static_cast<float>(n));
  engine.Push(static_cast<float>(j));
  if (!engine.DoOperator(PSOP_ROLL) ||
      engine.GetStackSize() != expected.size()) {
    std::fprintf(stderr, "FAIL %s: operator or stack size\n", name);
    return false;
  }
  for (auto it = expected.rbegin(); it != expected.rend(); ++it) {
    if (engine.Pop() != *it) {
      std::fprintf(stderr, "FAIL %s: stack value\n", name);
      return false;
    }
  }
  if (engine.GetStackSize() != 0) {
    std::fprintf(stderr, "FAIL %s: residual stack\n", name);
    return false;
  }
  return true;
}
}  // namespace

int main() {
  bool ok = true;
  const std::vector<float> input = {10, 20, 30, 40, 50};
  const std::vector<float> positive = {10, 20, 50, 30, 40};
  const std::vector<float> negative = {10, 20, 40, 50, 30};
  ok &= Check("positive", input, 3, 1, positive);
  ok &= Check("negative", input, 3, -1, negative);
  ok &= Check("positive-modulo", input, 3, 7, positive);
  ok &= Check("negative-modulo", input, 3, -7, negative);
  ok &= Check("whole-turn", input, 3, 6, input);
  ok &= Check("negative-whole-turn", input, 3, -6, input);
  ok &= Check("zero-rotation", input, 3, 0, input);
  ok &= Check("zero-count", input, 0, 1, input);
  ok &= Check("negative-count", input, -3, 1, input);
  ok &= Check("oversize-count", input, 6, 1, input);
  ok &= Check("empty", {}, 1, 1, {});
  ok &= Check("empty-zero", {}, 0, 0, {});
  ok &= Check("single", input, 1, -7, input);
  ok &= Check("full-payload", input, 5, 1, {50, 10, 20, 30, 40});
  CPDF_PSEngine empty;
  if (!empty.DoOperator(PSOP_ROLL) || empty.GetStackSize() != 0) {
    std::fprintf(stderr, "FAIL empty-without-operands\n");
    ok = false;
  }
  std::vector<float> capacity;
  std::vector<float> rotated;
  for (int i = 0; i < 98; ++i) {
    capacity.push_back(static_cast<float>(i));
    rotated.push_back(static_cast<float>((i + 97) % 98));
  }
  ok &= Check("near-capacity", capacity, 98, 1, rotated);
  ok &= Check("near-capacity-modulo", capacity, 98, 197, rotated);
  std::vector<float> reverse_rotated;
  for (int i = 0; i < 98; ++i) {
    reverse_rotated.push_back(static_cast<float>((i + 1) % 98));
  }
  ok &= Check("near-capacity-negative", capacity, 98, -197, reverse_rotated);
  ok &= Check("near-capacity-invalid", capacity, 99, -1, capacity);
  if (!ok) {
    return 1;
  }
  std::puts("pdfium-roll: pass");
  return 0;
}
