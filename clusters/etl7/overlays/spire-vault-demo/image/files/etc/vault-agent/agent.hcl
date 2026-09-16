# PLACEHOLDER — Story 6c provides final configuration
vault {
  address = "https://vault.apps.PLACEHOLDER_CLUSTER_BASE_DOMAIN"
}

auto_auth {
  method "jwt" {
    mount_path = "auth/spire-jwt/spire-jwt"
    config = {
      path                     = "/var/run/secrets/spiffe/jwt-svid.token"
      role                     = "spire-vm-role"
      remove_jwt_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/var/run/vault/token"
    }
  }
}

template {
  contents    = <<-EOF
    {{ with secret "secret/data/experiment/demo" }}{{ .Data.data.message }}{{ end }}
  EOF
  destination = "/var/www/html/secret.txt"
  perms       = "0644"
}
