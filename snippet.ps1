
      # Clean the cluster_ca to remove any whitespace or line breaks
      $cleanClusterCA = $env:cluster_ca -replace '\s+', ''

      # Output the length after cleaning
      Write-Host "Length of cleanClusterCA: $($cleanClusterCA.Length)"
