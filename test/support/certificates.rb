# frozen_string_literal: true

require "openssl"
require "tmpdir"
require "fileutils"

# Unit tests sign passes locally; they must never need a real Apple certificate.
directory = Dir.mktmpdir("passkit-test-certificates")
at_exit { FileUtils.remove_entry(directory) }
key = OpenSSL::PKey::RSA.new(2048)
certificate = OpenSSL::X509::Certificate.new
certificate.version = 2
certificate.serial = 1
certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=Passkit tests")
certificate.public_key = key.public_key
certificate.not_before = Time.now - 60
certificate.not_after = Time.now + 3600
certificate.sign(key, OpenSSL::Digest::SHA256.new)
password = "test-only"
p12_path = File.join(directory, "pass.p12")
certificate_path = File.join(directory, "certificate.pem")
File.binwrite(p12_path, OpenSSL::PKCS12.create(password, "tests", key, certificate).to_der)
File.write(certificate_path, certificate.to_pem)
ENV["PASSKIT_PRIVATE_P12_CERTIFICATE"] = p12_path
ENV["PASSKIT_APPLE_INTERMEDIATE_CERTIFICATE"] = certificate_path
ENV["PASSKIT_CERTIFICATE_KEY"] = password
ENV["PASSKIT_APPLE_TEAM_IDENTIFIER"] = "TESTTEAM"
ENV["PASSKIT_PASS_TYPE_IDENTIFIER"] = "pass.test.example"
ENV["PASSKIT_WEB_SERVICE_HOST"] = "https://example.test"
