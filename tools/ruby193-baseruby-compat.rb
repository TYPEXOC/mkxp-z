require 'erb'

class ERB
  alias_method :mkxp_z_original_initialize, :initialize

  def initialize(str, safe_level = nil, trim_mode = nil, eoutvar = '_erbout', **kwargs)
    if kwargs.empty?
      mkxp_z_original_initialize(str, trim_mode: trim_mode, eoutvar: eoutvar)
    else
      mkxp_z_original_initialize(str, **kwargs)
    end
  end
end
