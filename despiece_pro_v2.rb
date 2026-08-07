# despiece_pro_v2.rb
# Registrador de extension para SketchUp (copia de prueba CorteCloud)

require 'sketchup.rb'
require 'extensions.rb'

module BiraEstudio
  module DespieceProV2
    EXTENSION = SketchupExtension.new('Despiece PRO v2', 'despiece_pro_v2/main')
    EXTENSION.creator     = 'BiraEstudio'
    EXTENSION.description = 'Version de prueba con export a CorteCloud.'
    EXTENSION.version     = '2.0.0'
    EXTENSION.copyright   = '2024 BiraEstudio'
    Sketchup.register_extension(EXTENSION, true)
  end
end
