# ---------------------------------------------------------------------------
# SkyForge web board: S3 (private) + CloudFront.
#
# There is deliberately no API server. The DCS instance pushes small JSON files
# to S3 while it is running; the browser fetches them through CloudFront. An
# API would mean an always-on component sitting beside a game server that is
# asleep most of the week -- this way the only permanent cost is storage and
# request volume, which is pennies.
#
# The bucket stays private: CloudFront reaches it through an Origin Access
# Control, so there is no public bucket to misconfigure.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "board" {
  bucket = var.board_bucket
}

resource "aws_s3_bucket_public_access_block" "board" {
  bucket = aws_s3_bucket.board.id

  block_public_acls       = true
  block_public_policy     = false # the CloudFront-scoped policy below is not "public"
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "board" {
  bucket = aws_s3_bucket.board.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_cloudfront_origin_access_control" "board" {
  name                              = "${var.board_bucket}-oac"
  description                       = "SkyForge board access to the private bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "board" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "SkyForge DCS board"

  # PriceClass_100 is the cheapest tier. It excludes some edge locations, but
  # the audience is one friend group in India and the payload is tens of KB.
  price_class = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.board.bucket_regional_domain_name
    origin_id                = "board-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.board.id
  }

  default_cache_behavior {
    target_origin_id       = "board-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # CachingOptimized honours the origin's Cache-Control, which is how the
    # data files get a 10-second TTL while the app shell caches for longer.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # Default *.cloudfront.net certificate. A custom domain would need an ACM
    # cert in us-east-1 -- worth doing later if you want skyforge.yourdomain.
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "board_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.board.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.board.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "board" {
  bucket = aws_s3_bucket.board.id
  policy = data.aws_iam_policy_document.board_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.board]
}

output "board_url" {
  description = "Public URL for the SkyForge board."
  value       = "https://${aws_cloudfront_distribution.board.domain_name}"
}
