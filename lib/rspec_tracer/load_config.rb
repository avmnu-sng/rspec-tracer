# frozen_string_literal: true

require_relative 'configuration'
RSpecTracer.extend RSpecTracer::Configuration

require_relative 'load_default_config'
require_relative 'load_global_config'
require_relative 'load_local_config'

# NOTE: `Configuration#configure` installs the public DSL wrappers
# (alias `_name` + redefine `name` to forward `|*args, **kwargs, &block|`)
# the first time any configurer runs. `load_default_config` is
# unconditional, so the wrappers are guaranteed to exist before anyone
# can call `RSpecTracer.add_filter` etc. No second install step is
# needed here.
