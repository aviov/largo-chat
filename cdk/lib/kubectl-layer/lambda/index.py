def handler(event, context):
    # This is a minimal handler that does nothing
    # The actual kubectl operations will be handled by EKS
    return {
        'statusCode': 200,
        'body': 'Success'
    }
