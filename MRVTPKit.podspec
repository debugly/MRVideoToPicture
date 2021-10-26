#
# Be sure to run `pod lib lint MRVTPKit.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'MRVTPKit'
  s.version          = '0.4.2'
  s.summary          = 'extract pictures from video.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://github.com/debugly/MRVideoToPicture'
  s.license          = { :type => 'MIT', :text => 'LICENSE' }
  s.author           = { 'MattReach' => 'qianlongxu@gmail.com' }
  s.source           = { :git => 'https://github.com/debugly/MRVideoToPicture.git', :tag => s.version.to_s }

  s.osx.deployment_target = '10.11'
  
  s.pod_target_xcconfig = {
    'ALWAYS_SEARCH_USER_PATHS' => 'YES',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '${PODS_TARGET_SRCROOT}/MRVTPKit/MRFFmpegPod/macOS/4.4/include'],
    'EXCLUDED_ARCHS'=> 'arm64'
  }

  s.subspec 'common' do |ss|
    ss.source_files = 'MRVTPKit/common/**/*.{h,m}'
    ss.public_header_files = 'MRVTPKit/common/headers/public/*.h','MRVTPKit/common/*.h'
    ss.private_header_files = 'MRVTPKit/common/headers/private/*.h'
  end

  s.subspec 'core' do |ss|
    ss.source_files = 'MRVTPKit/core/*.{h,m}'
  end

  s.subspec 'sample' do |ss|
    ss.source_files = 'MRVTPKit/sample/*.{h,m}'
  end
  
  s.vendored_libraries = 'MRVTPKit/MRFFmpegPod/macOS/4.4/lib/*.a'

  s.library = 'z', 'bz2', 'iconv', 'lzma'
  s.frameworks = 'CoreFoundation', 'CoreVideo', 'VideoToolbox', 'CoreMedia', 'AudioToolbox'#, 'Security'

  
end
