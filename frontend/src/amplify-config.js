const awsconfig = {
    Auth: {
      region: 'eu-central-1', // Update to your region
      userPoolId: 'your-user-pool-id', // From CDK output
      userPoolWebClientId: 'your-client-id', // From CDK output
    },
    API: {
      endpoints: [
        {
          name: 'ChatApi',
          endpoint: 'your-api-url', // From CDK output
          custom_header: async () => ({
            Authorization: `Bearer ${(await Auth.currentSession()).getIdToken().getJwtToken()}`,
          }),
        },
      ],
    },
    Storage: {
      AWSS3: {
        bucket: 'your-bucket-name', // From CDK output or AWS Console
        region: 'eu-central-1', // Update to your region
      },
    },
  };
  
  export default awsconfig;