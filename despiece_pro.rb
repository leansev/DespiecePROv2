# despiece_pro.rb
# Registrador de extension para SketchUp

require 'sketchup.rb'
require 'extensions.rb'

module BiraEstudio
  module DespiecePro
    EXTENSION = SketchupExtension.new('Despiece PRO', 'despiece_pro/main')
    EXTENSION.creator     = 'BiraEstudio'
    EXTENSION.description = 'Escanea modulos MDF, agrupa piezas por dimensiones y color de placa, editor de tapacantos, panel de info de placas y export a Excel por placa.'
    EXTENSION.version     = '2.0.0'
    EXTENSION.copyright   = '2024 BiraEstudio'
    Sketchup.register_extension(EXTENSION, true)
  end
end
