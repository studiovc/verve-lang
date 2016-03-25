#include "gc.h"

namespace ceos {

  std::set<uint64_t> GC::roots;
  std::set<ScopePtr> GC::scopes;

}
