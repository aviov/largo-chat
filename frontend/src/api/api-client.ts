import axios from 'axios';

// Define the base URL for the API
// In production, this would come from environment variables
// For local development against your deployed Lambda:
const API_BASE_URL = process.env.REACT_APP_API_ENDPOINT || 'http://localhost:8000';

// Create an axios instance with the base URL
const apiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

// Interface for search requests
export interface SearchRequest {
  query: string;
  filters?: Record<string, any>;
  limit?: number;
}

// Interface for upload requests
export interface UploadRequest {
  files: File[];
  metadata?: Record<string, any>;
}

// API methods
export const api = {
  // Search in Milvus
  search: async (request: SearchRequest) => {
    const response = await apiClient.post('/search', request);
    return response.data;
  },

  // Upload files to be processed and stored in Milvus
  upload: async (request: UploadRequest) => {
    const formData = new FormData();
    
    request.files.forEach((file, index) => {
      formData.append(`file${index}`, file);
    });
    
    if (request.metadata) {
      formData.append('metadata', JSON.stringify(request.metadata));
    }
    
    const response = await apiClient.post('/upload', formData, {
      headers: {
        'Content-Type': 'multipart/form-data',
      },
    });
    
    return response.data;
  },

  // Get collection info from Milvus
  getCollections: async () => {
    const response = await apiClient.get('/collections');
    return response.data;
  },

  // Health check endpoint
  health: async () => {
    const response = await apiClient.get('/health');
    return response.data;
  }
};
