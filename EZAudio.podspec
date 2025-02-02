Pod::Spec.new do |s|
    s.name         = "EZAudio"
    s.version      = "1.1.5"
    s.summary      = "A simple, intuitive audio framework for iOS and OSX useful for anyone doing audio processing and/or audio-based visualizations."
    s.homepage     = "https://github.com/syedhali/EZAudio"
    s.screenshots  = "https://s3-us-west-1.amazonaws.com/ezaudio-media/EZAudioSummary.png"
    s.license      = { :type => 'MIT', :file => 'LICENSE' }
    s.author       = { "Syed Haris Ali" => "syedhali07@gmail.com" }
    s.ios.deployment_target = '8.0'
    s.osx.deployment_target = '10.8'
    s.source       = { :git => "https://github.com/syedhali/EZAudio.git", :tag => s.version }
    s.exclude_files = [ 'EZAudio/TPCircularBuffer.{h,c}', 'EZAudio/EZAudioiOS.h', 'EZAudio/EZAudioOSX.h' ]
    s.ios.frameworks = 'AudioToolbox','AVFoundation','GLKit', 'Accelerate'
    s.osx.frameworks = 'AudioToolbox','AudioUnit','CoreAudio','QuartzCore','OpenGL','GLKit', 'Accelerate'
    s.requires_arc = true;
    s.default_subspec = 'Full'
    s.subspec 'Core' do |core|
        core.source_files  = 'EZAudio/*.{h,m,c,mm}'
    end

    s.subspec 'Full' do |full|
        full.dependency 'EZAudio/Core'
    end
end
