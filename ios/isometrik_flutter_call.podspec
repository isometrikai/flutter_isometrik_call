#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint isometrik_flutter_call.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'isometrik_flutter_call'
  s.version          = '0.0.1'
  s.summary          = 'Flutter calling SDK bridge for CallKit/PushKit.'
  s.description      = <<-DESC
Flutter package that exposes iOS CallKit + PushKit primitives and
LiveKit-first call controls to Flutter applications.
                       DESC
  s.homepage         = 'https://github.com/isometrik/isometrik_flutter_call'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Isometrik' => 'support@isometrik.io' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  # Keep in sync with flutter_webrtc’s WebRTC-SDK pin so CallKit can notify RTCAudioSession.
  s.dependency 'WebRTC-SDK', '137.7151.04'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'isometrik_flutter_call_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
