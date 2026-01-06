find . -name "*.yaml" -exec sed -i '/^support-os:/,/^[^[:space:]]/d' {} +
