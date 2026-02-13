# frozen_string_literal: true

require_relative "http/errors"
require_relative "http/connection_pool"
require_relative "http/connection_pool_manager"
require_relative "http/handler"
require_relative "http/plugin"
require_relative "http/patcher"

# Auto-patch all loaded and future AWS service clients
AwsCrt::Http::Patcher.patch!
