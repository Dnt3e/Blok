<template>
  <v-container>
    <v-row>
      <v-col cols="12">
        <v-card class="pa-4">
          <v-card-title class="text-h5">VPN Users</v-card-title>
          <v-data-table
            :headers="headers"
            :items="users"
            :loading="loading"
          >
            <template v-slot:item.actions="{ item }">
              <v-btn small color="primary" @click="editUser(item)">Edit</v-btn>
              <v-btn small color="error" @click="deleteUser(item)">Delete</v-btn>
              <v-btn small color="success" @click="showConfig(item)">Config</v-btn>
            </template>
          </v-data-table>
        </v-card>
      </v-col>
    </v-row>
  </v-container>
</template>

<script>
export default {
  data() {
    return {
      loading: false,
      users: [],
      headers: [
        { text: 'Username', value: 'username' },
        { text: 'Data Limit', value: 'dataLimit' },
        { text: 'Expiry Date', value: 'expiryDate' },
        { text: 'Actions', value: 'actions' }
      ]
    };
  },
  async created() {
    await this.fetchUsers();
  },
  methods: {
    async fetchUsers() {
      this.loading = true;
      try {
        const response = await this.$http.get('/api/users');
        this.users = response.data;
      } catch (error) {
        console.error(error);
      } finally {
        this.loading = false;
      }
    },
    editUser(user) {
      // Implement edit logic
    },
    deleteUser(user) {
      // Implement delete logic
    },
    showConfig(user) {
      // Show config with QR code
    }
  }
};
</script>
