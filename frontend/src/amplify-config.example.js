const awsconfig = {
    Auth: {
      region: 'eu-central-1', // Update to your region
      userPoolId: 'USER_POOL_ID', // From CDK output
      userPoolWebClientId: 'USER_POOL_CLIENT_ID', // From CDK output
    },
    API: {
      endpoints: [
        {
          name: 'ChatApi',
          endpoint: 'API_ENDPOINT', // From CDK output
          custom_header: async () => ({
            Authorization: `Bearer ${(await Auth.currentSession()).getIdToken().getJwtToken()}`,
          }),
        },
      ],
    },
    Storage: {
      AWSS3: {
        bucket: 'BUCKET_NAME', // From CDK output or AWS Console
        region: 'eu-central-1', // Update to your region
      },
    },
  };
  
  export default awsconfig;